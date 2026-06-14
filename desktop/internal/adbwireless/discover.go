// Package adbwireless drives the Android 11+ "wireless debugging" handshake
// from the desktop side. It scans the LAN over mDNS for two service types
// that adbd advertises and exposes a small Go API the Wails app layer can
// expose to the React UI.
//
// Two mDNS service types are relevant:
//
//   _adb-tls-pairing._tcp.local.  - present only while the user has the
//                                   "Pair device with pairing code" dialog
//                                   open on the phone. Lives for ~minutes.
//   _adb-tls-connect._tcp.local.  - present whenever "Wireless debugging" is
//                                   toggled on, regardless of pairing state.
//
// Both port numbers rotate on every toggle, which is the whole reason this
// discovery exists: typing them in by hand is the slow path.
package adbwireless

import (
	"context"
	"fmt"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/grandcat/zeroconf"
)

// Endpoint represents a single live mDNS-advertised adb endpoint.
type Endpoint struct {
	Kind     string    `json:"kind"`     // "pairing" or "connect"
	Instance string    `json:"instance"` // mDNS instance name, e.g. "adb-XXXX"
	Host     string    `json:"host"`     // resolved IPv4 we hand to `adb pair`/`adb connect`
	Port     int       `json:"port"`
	SeenAt   time.Time `json:"seenAt"`
}

// Address returns "host:port", the form `adb` accepts.
func (e Endpoint) Address() string { return fmt.Sprintf("%s:%d", e.Host, e.Port) }

// Discoverer maintains the live set of pairing + connect endpoints and emits
// the merged list on every change via the callback the caller registers.
//
// Endpoints disappear from the set after `ttl` of silence so a closed
// pairing dialog stops showing as a candidate.
type Discoverer struct {
	ttl     time.Duration
	onEvent func([]Endpoint)

	mu      sync.Mutex
	entries map[string]Endpoint // key: kind + "|" + Address()

	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// NewDiscoverer builds a discoverer with a sensible default TTL (45 s).
// Pass onEvent=nil to use polling via Snapshot instead.
func NewDiscoverer(onEvent func([]Endpoint)) *Discoverer {
	return &Discoverer{
		ttl:     45 * time.Second,
		onEvent: onEvent,
		entries: map[string]Endpoint{},
	}
}

// Start kicks off two Browse goroutines (one per service type) plus a janitor
// that prunes expired entries. Calling Start twice is a no-op.
func (d *Discoverer) Start() error {
	d.mu.Lock()
	if d.cancel != nil {
		d.mu.Unlock()
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	d.cancel = cancel
	d.mu.Unlock()

	// On multi-NIC machines — proxy TUN (198.18.x fake-ip), VMware VMnet,
	// WSL/Hyper-V vEthernet — the default "all interfaces" mode leaks the mDNS
	// query out the wrong adapter and the phone's reply never makes it back,
	// which is exactly the "discovery works sometimes, not others" flakiness.
	// Restrict to real LAN interfaces and IPv4 (adbd advertises over v4). Fall
	// back to zeroconf's all-interfaces default if the filter finds nothing, so
	// an unusual setup degrades to "noisy" rather than "blind".
	ropts := []zeroconf.ClientOption{zeroconf.SelectIPTraffic(zeroconf.IPv4)}
	if ifaces := lanInterfaces(); len(ifaces) > 0 {
		ropts = append(ropts, zeroconf.SelectIfaces(ifaces))
	}
	resolver, err := zeroconf.NewResolver(ropts...)
	if err != nil {
		d.Stop()
		return fmt.Errorf("zeroconf resolver: %w", err)
	}

	d.wg.Add(3)
	go d.browse(ctx, resolver, "_adb-tls-pairing._tcp", "pairing")
	go d.browse(ctx, resolver, "_adb-tls-connect._tcp", "connect")
	go d.janitor(ctx)
	return nil
}

func (d *Discoverer) browse(ctx context.Context, r *zeroconf.Resolver, service, kind string) {
	defer d.wg.Done()
	entries := make(chan *zeroconf.ServiceEntry, 8)

	// Browse blocks until ctx is done. We loop with a re-Browse on errors so
	// the discovery survives transient mDNS hiccups (NIC flap, etc.).
	go func() {
		for {
			err := r.Browse(ctx, service, "local.", entries)
			if ctx.Err() != nil {
				return
			}
			if err != nil {
				time.Sleep(2 * time.Second)
				continue
			}
			return
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return
		case e, ok := <-entries:
			if !ok {
				return
			}
			if e == nil || len(e.AddrIPv4) == 0 || e.Port == 0 {
				continue
			}
			ep := Endpoint{
				Kind:     kind,
				Instance: e.Instance,
				Host:     e.AddrIPv4[0].String(),
				Port:     e.Port,
				SeenAt:   time.Now(),
			}
			d.upsert(ep)
		}
	}
}

func (d *Discoverer) janitor(ctx context.Context) {
	defer d.wg.Done()
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			d.expire()
		}
	}
}

func (d *Discoverer) upsert(ep Endpoint) {
	d.mu.Lock()
	key := ep.Kind + "|" + ep.Address()
	prev, existed := d.entries[key]
	d.entries[key] = ep
	changed := !existed || prev.Host != ep.Host || prev.Port != ep.Port || prev.Instance != ep.Instance
	snap := d.snapshotLocked()
	d.mu.Unlock()
	if changed && d.onEvent != nil {
		d.onEvent(snap)
	}
}

func (d *Discoverer) expire() {
	cutoff := time.Now().Add(-d.ttl)
	d.mu.Lock()
	changed := false
	for k, v := range d.entries {
		if v.SeenAt.Before(cutoff) {
			delete(d.entries, k)
			changed = true
		}
	}
	snap := d.snapshotLocked()
	d.mu.Unlock()
	if changed && d.onEvent != nil {
		d.onEvent(snap)
	}
}

// Snapshot returns the current endpoint set, sorted: pairing first (since the
// user is usually waiting on the dialog), then connect, both by host.
func (d *Discoverer) Snapshot() []Endpoint {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.snapshotLocked()
}

func (d *Discoverer) snapshotLocked() []Endpoint {
	out := make([]Endpoint, 0, len(d.entries))
	for _, v := range d.entries {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind == "pairing"
		}
		if out[i].Host != out[j].Host {
			return out[i].Host < out[j].Host
		}
		return out[i].Port < out[j].Port
	})
	return out
}

// Stop cancels the browse goroutines and waits for cleanup.
func (d *Discoverer) Stop() {
	d.mu.Lock()
	cancel := d.cancel
	d.cancel = nil
	d.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	d.wg.Wait()
}

// lanInterfaces returns the physical LAN interfaces worth doing mDNS on,
// filtering out the virtual adapters (proxy/VPN TUN, VMware, WSL/Hyper-V,
// Docker, etc.) that otherwise swallow or misroute the multicast query on a
// multi-NIC host. Returns nil when nothing qualifies so the caller can fall
// back to zeroconf's all-interfaces default instead of going blind.
func lanInterfaces() []net.Interface {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []net.Interface
	for _, ifi := range ifaces {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagMulticast == 0 {
			continue
		}
		if ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		if isVirtualIface(ifi.Name) || !hasUsablePrivateIPv4(ifi) {
			continue
		}
		out = append(out, ifi)
	}
	return out
}

// isVirtualIface matches the adapter names used by proxies, VMs and tunnels so
// they can be skipped. Substring match on a lowercased name; deliberately
// broad since a false positive only drops a non-LAN NIC.
func isVirtualIface(name string) bool {
	n := strings.ToLower(name)
	for _, bad := range []string{
		"vmware", "vethernet", "hyper-v", "virtualbox", "vbox",
		"vpn", "tailscale", "zerotier", "docker", "wsl",
		"tap", "tun", "loopback", "bluetooth", "wan miniport",
	} {
		if strings.Contains(n, bad) {
			return true
		}
	}
	return false
}

// hasUsablePrivateIPv4 reports whether the interface carries a normal RFC1918
// LAN address, excluding APIPA link-local (169.254/16) and the 198.18/15
// benchmark range that fake-ip proxies (Clash/Surge) hand out.
func hasUsablePrivateIPv4(ifi net.Interface) bool {
	addrs, err := ifi.Addrs()
	if err != nil {
		return false
	}
	for _, a := range addrs {
		var ip net.IP
		switch v := a.(type) {
		case *net.IPNet:
			ip = v.IP
		case *net.IPAddr:
			ip = v.IP
		}
		ip4 := ip.To4()
		if ip4 == nil {
			continue
		}
		if ip4[0] == 169 && ip4[1] == 254 {
			continue // APIPA link-local
		}
		if ip4[0] == 198 && (ip4[1] == 18 || ip4[1] == 19) {
			continue // 198.18/15 benchmark / fake-ip
		}
		if ip4.IsPrivate() {
			return true
		}
	}
	return false
}

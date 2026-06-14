package transport

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"sync/atomic"
	"time"
)

// DefaultBeaconPort is the UDP port the desktop broadcasts on and the mobile
// listens on for service announcements. Sits adjacent to the WS port for easy
// firewall-rule writing.
const DefaultBeaconPort = 53117

// beaconPacket is the JSON payload sent on every broadcast tick.
type beaconPacket struct {
	Type string `json:"type"`
	Name string `json:"name"`
	Port int    `json:"port"`
	V    int    `json:"v"`
}

// UDPBeacon broadcasts a small JSON packet on every detected LAN interface
// every 2 s so mobile clients that can't use mDNS (some Wi-Fi APs block
// multicast) can still locate the desktop. Per-interface sockets bound to
// the local IP guarantee that the broadcast really leaves the right NIC and
// isn't silently sent down a virtual adapter the phone can't see.
type UDPBeacon struct {
	beaconPort int
	wsPort     int
	conns      []boundConn
	stop       chan struct{}
	running    atomic.Bool
}

type boundConn struct {
	conn     *net.UDPConn
	dstSpec  []*net.UDPAddr // limited broadcast + subnet broadcast
}

func NewUDPBeacon(beaconPort, wsPort int) *UDPBeacon {
	return &UDPBeacon{beaconPort: beaconPort, wsPort: wsPort}
}

func (b *UDPBeacon) Start(ctx context.Context) error {
	if !b.running.CompareAndSwap(false, true) {
		return nil
	}

	hostname, _ := os.Hostname()
	if hostname == "" {
		hostname = "VoiceInput"
	}
	pkt, _ := json.Marshal(beaconPacket{
		Type: "voiceinput.beacon",
		Name: hostname,
		Port: b.wsPort,
		V:    1,
	})

	// Open one socket per LAN interface, bound to its local IP, so the OS
	// routes broadcasts out exactly that adapter.
	lans := DiscoverLANInterfaces()
	var conns []boundConn
	for _, l := range lans {
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: l.LocalIP, Port: 0})
		if err != nil {
			continue
		}
		if err := setBroadcast(conn); err != nil {
			_ = conn.Close()
			continue
		}
		conns = append(conns, boundConn{
			conn: conn,
			dstSpec: []*net.UDPAddr{
				{IP: net.IPv4bcast, Port: b.beaconPort},
				{IP: l.BroadcastIP, Port: b.beaconPort},
			},
		})
	}

	if len(conns) == 0 {
		// Fallback: single 0.0.0.0-bound socket. Better than nothing on weird
		// network configs (e.g. VPN-only machines).
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
		if err != nil {
			b.running.Store(false)
			return err
		}
		if err := setBroadcast(conn); err != nil {
			_ = conn.Close()
			b.running.Store(false)
			return err
		}
		conns = append(conns, boundConn{
			conn: conn,
			dstSpec: []*net.UDPAddr{{IP: net.IPv4bcast, Port: b.beaconPort}},
		})
	}

	b.conns = conns
	b.stop = make(chan struct{})

	go func() {
		tick := func() {
			for _, bc := range conns {
				for _, dst := range bc.dstSpec {
					_, _ = bc.conn.WriteToUDP(pkt, dst)
				}
			}
		}
		tick() // fire one immediately so a freshly-launched mobile sees us within ms
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-b.stop:
				return
			case <-t.C:
				tick()
			}
		}
	}()
	return nil
}

func (b *UDPBeacon) Stop() {
	if !b.running.CompareAndSwap(true, false) {
		return
	}
	close(b.stop)
	for _, bc := range b.conns {
		_ = bc.conn.Close()
	}
	b.conns = nil
}

// setBroadcast enables SO_BROADCAST on the UDP socket. Pulled out so the
// platform-specific syscall details stay isolated; net.UDPConn doesn't expose
// it directly cross-platform.
func setBroadcast(conn *net.UDPConn) error {
	rc, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var setErr error
	err = rc.Control(func(fd uintptr) {
		setErr = enableBroadcast(fd)
	})
	if err != nil {
		return err
	}
	return setErr
}

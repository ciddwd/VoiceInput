package transport

import (
	"context"
	"fmt"
	"net"
	"os"

	"github.com/grandcat/zeroconf"
)

// MDNSPublisher advertises this desktop as a _voiceinput._tcp.local. service
// so mobile clients can find it without typing an IP.
//
// We pass the LAN interfaces explicitly to zeroconf so multicast announce
// goes out only the user's Wi-Fi / Ethernet adapter and not the parade of
// WSL / Hyper-V / VPN virtual NICs that otherwise hide the desktop behind
// the wrong source IP.
type MDNSPublisher struct {
	server *zeroconf.Server
}

func NewMDNSPublisher() *MDNSPublisher { return &MDNSPublisher{} }

// Start registers the mDNS service. instance defaults to hostname when empty.
func (m *MDNSPublisher) Start(_ context.Context, instance string, port int) error {
	if instance == "" {
		h, err := os.Hostname()
		if err != nil || h == "" {
			h = "VoiceInput"
		}
		instance = h
	}

	lans := DiscoverLANInterfaces()
	var ifaces []net.Interface
	for _, l := range lans {
		ifaces = append(ifaces, l.Iface)
	}
	txt := []string{fmt.Sprintf("port=%d", port), "v=1"}

	srv, err := zeroconf.Register(
		instance, "_voiceinput._tcp", "local.", port,
		txt, ifaces, // nil means all interfaces; non-nil restricts to LAN NICs
	)
	if err != nil {
		return fmt.Errorf("mdns register: %w", err)
	}
	m.server = srv
	return nil
}

func (m *MDNSPublisher) Stop() {
	if m.server != nil {
		m.server.Shutdown()
		m.server = nil
	}
}

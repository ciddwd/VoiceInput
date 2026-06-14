package transport

import (
	"net"
	"strings"
)

// LANInterface describes one real network interface the desktop should
// advertise on. We deliberately skip loopback, link-local, and the various
// virtual NICs (VirtualBox/WSL/Hyper-V/VPN) so mDNS and UDP broadcast go out
// only the user's actual Wi-Fi / Ethernet adapter — those virtual NICs are
// the usual reason mobile clients can't see the desktop.
type LANInterface struct {
	Iface     net.Interface
	LocalIP   net.IP
	BroadcastIP net.IP
}

// DiscoverLANInterfaces returns every up, broadcast-capable interface with at
// least one usable IPv4 address. We prefer private-range RFC1918 addresses
// (192.168/16, 10/8, 172.16/12) and discard everything else.
func DiscoverLANInterfaces() []LANInterface {
	var out []LANInterface
	ifaces, err := net.Interfaces()
	if err != nil {
		return out
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		if iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if iface.Flags&net.FlagBroadcast == 0 {
			continue
		}
		// The flag + RFC1918 checks alone do NOT exclude VMware / WSL / Hyper-V
		// adapters — those carry private IPs too (192.168.x from VMnet, 172.x
		// from WSL), so without this a mobile client can latch onto an
		// unreachable virtual-NIC address and fail to connect. Drop by name.
		if isVirtualIface(iface.Name) {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipNet.IP.To4()
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
			if !isRFC1918(ip) {
				continue
			}
			bcast := make(net.IP, 4)
			for i := 0; i < 4; i++ {
				bcast[i] = ip[i] | ^ipNet.Mask[i]
			}
			out = append(out, LANInterface{Iface: iface, LocalIP: ip, BroadcastIP: bcast})
		}
	}
	return out
}

func isRFC1918(ip net.IP) bool {
	ip = ip.To4()
	if ip == nil {
		return false
	}
	switch {
	case ip[0] == 10:
		return true
	case ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31:
		return true
	case ip[0] == 192 && ip[1] == 168:
		return true
	}
	return false
}

// isVirtualIface matches adapter names used by VMs, containers, tunnels and
// proxies. They carry RFC1918 IPs but aren't the user's real LAN, and
// advertising on them hands mobile clients an unreachable address. (Mirrors the
// same filter in internal/adbwireless; kept local to avoid a shared dep.)
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

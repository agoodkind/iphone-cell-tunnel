//go:build darwin

package discovery

import (
	"net"
	"net/netip"
)

func scopedHost(host string, family AddressFamily, interfaceIndex uint32) string {
	if family != AddressFamilyIPv6 {
		return host
	}

	address, err := netip.ParseAddr(host)
	if err != nil || !address.IsLinkLocalUnicast() {
		return host
	}

	networkInterface, err := net.InterfaceByIndex(int(interfaceIndex))
	if err != nil || networkInterface.Name == "" {
		return host
	}
	return host + "%" + networkInterface.Name
}

func isUSBLocalInterface(interfaceIndex uint32) bool {
	networkInterface, err := net.InterfaceByIndex(int(interfaceIndex))
	if err != nil {
		return false
	}

	addresses, err := networkInterface.Addrs()
	if err != nil {
		return false
	}

	for _, address := range addresses {
		networkAddress, ok := address.(*net.IPNet)
		if !ok {
			continue
		}
		ipv4Address := networkAddress.IP.To4()
		if ipv4Address == nil {
			continue
		}
		if ipv4Address[0] == 169 && ipv4Address[1] == 254 {
			return true
		}
	}

	return false
}

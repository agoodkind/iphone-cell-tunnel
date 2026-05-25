//go:build !darwin

package discovery

func scopedHost(host string, family AddressFamily, interfaceIndex uint32) string {
	return host
}

func isUSBLocalInterface(interfaceIndex uint32) bool {
	return false
}

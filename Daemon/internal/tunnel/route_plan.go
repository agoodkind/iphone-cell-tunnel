package tunnel

import (
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

// RoutePlan describes the typed native network mutations needed by the runtime.
type RoutePlan struct {
	InterfaceName           string
	IPv4Routes              []string
	IPv6Routes              []string
	LocalRelayPreservations []LocalRelayPreservation
	InstallOperations       []NetworkOperation
	RemoveOperations        []NetworkOperation
}

// LocalRelayPreservation records the local iPhone relay route that must survive default route changes.
type LocalRelayPreservation struct {
	EndpointHost      string
	EndpointInterface string
	AddressFamily     RelayAddressFamily
}

// NetworkOperationKind identifies the closed set of native interface and route mutations.
type NetworkOperationKind string

const (
	networkOperationIPv4Address         NetworkOperationKind = "ipv4-address"
	networkOperationIPv6Address         NetworkOperationKind = "ipv6-address"
	networkOperationInterfaceMTUAndUp   NetworkOperationKind = "interface-mtu-up"
	networkOperationAddIPv4Route        NetworkOperationKind = "add-ipv4-route"
	networkOperationAddIPv6Route        NetworkOperationKind = "add-ipv6-route"
	networkOperationDeleteIPv4Route     NetworkOperationKind = "delete-ipv4-route"
	networkOperationDeleteIPv6Route     NetworkOperationKind = "delete-ipv6-route"
	networkOperationAddIPv4RelayHost    NetworkOperationKind = "add-ipv4-relay-host"
	networkOperationAddIPv6RelayHost    NetworkOperationKind = "add-ipv6-relay-host"
	networkOperationDeleteIPv4RelayHost NetworkOperationKind = "delete-ipv4-relay-host"
	networkOperationDeleteIPv6RelayHost NetworkOperationKind = "delete-ipv6-relay-host"
)

var errUnscopedIPv6LinkLocalRelay = errors.New("ipv6 link-local relay endpoint is unscoped")

// NetworkOperation is the typed runtime form of one native network mutation.
type NetworkOperation struct {
	Kind           NetworkOperationKind
	InterfaceName  string
	Address        string
	PeerAddress    string
	PrefixLength   int
	MTU            int
	EndpointHost   string
	RelayInterface string
	AddressFamily  RelayAddressFamily
}

// String renders a typed operation for dry-run output.
func (operation NetworkOperation) String() string {
	parts := []string{
		"operation=" + string(operation.Kind),
	}
	if operation.InterfaceName != "" {
		parts = append(parts, "interface="+operation.InterfaceName)
	}
	if operation.Address != "" {
		parts = append(parts, "address="+operation.Address)
	}
	if operation.PeerAddress != "" {
		parts = append(parts, "peer="+operation.PeerAddress)
	}
	if operation.PrefixLength > 0 {
		parts = append(parts, "prefix="+strconv.Itoa(operation.PrefixLength))
	}
	if operation.MTU > 0 {
		parts = append(parts, "mtu="+strconv.Itoa(operation.MTU))
	}
	if operation.EndpointHost != "" {
		parts = append(parts, "host="+operation.EndpointHost)
	}
	if operation.RelayInterface != "" {
		parts = append(parts, "relay_interface="+operation.RelayInterface)
	}
	if operation.AddressFamily != 0 {
		parts = append(parts, "family="+strconv.Itoa(int(operation.AddressFamily)))
	}
	return strings.Join(parts, " ")
}

// String renders the local relay preservation marker for dry-run output.
func (preservation LocalRelayPreservation) String() string {
	parts := []string{
		"host=" + preservation.EndpointHost,
	}
	if preservation.EndpointInterface != "" {
		parts = append(parts, "interface="+preservation.EndpointInterface)
	}
	parts = append(parts, "family="+strconv.Itoa(int(preservation.AddressFamily)))
	return strings.Join(parts, " ")
}

// BuildRoutePlan creates the native route mutation plan from the WireGuard AllowedIPs.
func BuildRoutePlan(config Config, wireGuardConfig WireGuardConfig, interfaceName string) RoutePlan {
	interfaceName = resolvedInterfaceName(config, interfaceName)
	installOperations := buildInstallOperations(config, wireGuardConfig, interfaceName)
	removeOperations := buildRemoveOperations(wireGuardConfig)
	preservations := buildLocalRelayPreservations(config)
	ipv4Routes, ipv6Routes := groupedAllowedIPRoutes(wireGuardConfig)

	plan := RoutePlan{
		InterfaceName:           interfaceName,
		IPv4Routes:              ipv4Routes,
		IPv6Routes:              ipv6Routes,
		LocalRelayPreservations: preservations,
		InstallOperations:       installOperations,
		RemoveOperations:        removeOperations,
	}
	logger.Info(
		"route plan built",
		"interface_name",
		plan.InterfaceName,
		"install_operations",
		len(plan.InstallOperations),
		"remove_operations",
		len(plan.RemoveOperations),
		"local_relay_preservations",
		len(plan.LocalRelayPreservations),
	)
	return plan
}

func buildLocalRelayPreservations(config Config) []LocalRelayPreservation {
	if config.LocalRelayEndpoint == "" {
		logger.Info("route plan local relay preservation skipped because endpoint is not configured")
		return []LocalRelayPreservation{}
	}

	if strings.HasPrefix(config.LocalRelayEndpoint, usbmuxdRelayPrefix) {
		logger.Info("route plan local relay preservation skipped because endpoint uses usbmuxd transport")
		return []LocalRelayPreservation{}
	}

	endpoint, err := ParseWireGuardEndpoint(config.LocalRelayEndpoint)
	if err != nil {
		host, _, splitErr := net.SplitHostPort(config.LocalRelayEndpoint)
		if splitErr != nil {
			logger.Error("route plan local relay endpoint parse failed", "err", err)
			return []LocalRelayPreservation{}
		}
		endpoint = RelayEndpoint{
			AddressFamily: localRelayHostFamily(host),
			Host:          host,
		}
	}

	if isLoopbackHost(endpoint.Host) {
		logger.Info("route plan local relay preservation skipped because endpoint is loopback")
		return []LocalRelayPreservation{}
	}

	endpointHost, endpointInterface := scopedHostParts(endpoint.Host)
	if isUnscopedIPv6LinkLocal(endpointHost, endpointInterface, endpoint.AddressFamily) {
		logger.Error(
			"route plan local relay preservation skipped",
			"err",
			errUnscopedIPv6LinkLocalRelay,
		)
		return []LocalRelayPreservation{}
	}

	preservation := LocalRelayPreservation{
		EndpointHost:      endpointHost,
		EndpointInterface: endpointInterface,
		AddressFamily:     endpoint.AddressFamily,
	}
	logger.Info(
		"route plan local relay preservation represented",
		"endpoint_family",
		preservation.AddressFamily,
		"endpoint_interface_configured",
		preservation.EndpointInterface != "",
	)
	return []LocalRelayPreservation{preservation}
}

func localRelayHostFamily(host string) RelayAddressFamily {
	address, err := netip.ParseAddr(stripScopedHost(host))
	if err == nil && address.Is6() {
		return RelayAddressFamilyIPv6
	}
	return RelayAddressFamilyIPv4
}

func isLoopbackHost(host string) bool {
	address, err := netip.ParseAddr(stripScopedHost(host))
	if err != nil {
		return false
	}
	return address.IsLoopback()
}

func isUnscopedIPv6LinkLocal(
	host string,
	endpointInterface string,
	addressFamily RelayAddressFamily,
) bool {
	if addressFamily != RelayAddressFamilyIPv6 || endpointInterface != "" {
		return false
	}
	address, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	return address.IsLinkLocalUnicast()
}

func resolvedInterfaceName(config Config, interfaceName string) string {
	if interfaceName == "" {
		logger.Info("route plan using interface hint", "interface_hint", config.InterfaceNameHint)
		return config.InterfaceNameHint + "*"
	}

	logger.Info("route plan using concrete interface", "interface_name", interfaceName)
	return interfaceName
}

func buildInstallOperations(
	config Config,
	wireGuardConfig WireGuardConfig,
	interfaceName string,
) []NetworkOperation {
	operations := []NetworkOperation{
		{
			Kind:          networkOperationIPv4Address,
			InterfaceName: interfaceName,
			Address:       config.IPv4Address,
			PeerAddress:   config.IPv4PeerAddress,
			PrefixLength:  config.IPv4PrefixLength,
		},
		{
			Kind:          networkOperationIPv6Address,
			InterfaceName: interfaceName,
			Address:       config.IPv6Address,
			PrefixLength:  config.IPv6PrefixLength,
		},
		{
			Kind:          networkOperationInterfaceMTUAndUp,
			InterfaceName: interfaceName,
			MTU:           config.MTU,
		},
	}

	for _, allowedIP := range wireGuardConfig.Peer.AllowedIPs {
		operations = append(operations, routeOperationForPrefix(allowedIP, interfaceName, true))
	}
	return operations
}

func buildRemoveOperations(wireGuardConfig WireGuardConfig) []NetworkOperation {
	operations := make([]NetworkOperation, 0, len(wireGuardConfig.Peer.AllowedIPs))
	for _, allowedIP := range wireGuardConfig.Peer.AllowedIPs {
		operations = append(operations, routeOperationForPrefix(allowedIP, "", false))
	}
	return operations
}

func groupedAllowedIPRoutes(wireGuardConfig WireGuardConfig) ([]string, []string) {
	ipv4Routes := make([]string, 0, len(wireGuardConfig.Peer.AllowedIPs))
	ipv6Routes := make([]string, 0, len(wireGuardConfig.Peer.AllowedIPs))
	for _, allowedIP := range wireGuardConfig.Peer.AllowedIPs {
		if allowedIP.Addr().Is4() {
			ipv4Routes = append(ipv4Routes, allowedIP.String())
			continue
		}
		if allowedIP.Addr().Is6() {
			ipv6Routes = append(ipv6Routes, allowedIP.String())
		}
	}
	return ipv4Routes, ipv6Routes
}

func routeOperationForPrefix(
	prefix netip.Prefix,
	interfaceName string,
	install bool,
) NetworkOperation {
	operation := NetworkOperation{
		InterfaceName: interfaceName,
		Address:       prefix.Addr().String(),
		PrefixLength:  prefix.Bits(),
	}
	if prefix.Addr().Is4() {
		operation.AddressFamily = RelayAddressFamilyIPv4
		if install {
			operation.Kind = networkOperationAddIPv4Route
		} else {
			operation.Kind = networkOperationDeleteIPv4Route
		}
		return operation
	}

	operation.AddressFamily = RelayAddressFamilyIPv6
	if install {
		operation.Kind = networkOperationAddIPv6Route
	} else {
		operation.Kind = networkOperationDeleteIPv6Route
	}
	return operation
}

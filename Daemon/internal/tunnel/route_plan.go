package tunnel

import (
	"net"
	"net/netip"
	"strconv"
	"strings"
)

const (
	defaultIPv4Route = "0.0.0.0/0"
	defaultIPv6Route = "::/0"
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
	EndpointHost  string
	AddressFamily RelayAddressFamily
}

// NetworkOperationKind identifies the closed set of native interface and route mutations.
type NetworkOperationKind string

const (
	networkOperationIPv4Address         NetworkOperationKind = "ipv4-address"
	networkOperationIPv6Address         NetworkOperationKind = "ipv6-address"
	networkOperationInterfaceMTUAndUp   NetworkOperationKind = "interface-mtu-up"
	networkOperationAddIPv4Default      NetworkOperationKind = "add-ipv4-default"
	networkOperationAddIPv6Default      NetworkOperationKind = "add-ipv6-default"
	networkOperationDeleteIPv4Default   NetworkOperationKind = "delete-ipv4-default"
	networkOperationDeleteIPv6Default   NetworkOperationKind = "delete-ipv6-default"
	networkOperationAddIPv4RelayHost    NetworkOperationKind = "add-ipv4-relay-host"
	networkOperationAddIPv6RelayHost    NetworkOperationKind = "add-ipv6-relay-host"
	networkOperationDeleteIPv4RelayHost NetworkOperationKind = "delete-ipv4-relay-host"
	networkOperationDeleteIPv6RelayHost NetworkOperationKind = "delete-ipv6-relay-host"
)

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
	return "host=" + preservation.EndpointHost +
		" family=" + strconv.Itoa(int(preservation.AddressFamily))
}

// BuildRoutePlan creates the dual-stack native route mutation plan.
func BuildRoutePlan(config Config, interfaceName string) RoutePlan {
	interfaceName = resolvedInterfaceName(config, interfaceName)
	installOperations := buildInstallOperations(config, interfaceName)
	removeOperations := buildRemoveOperations(interfaceName)
	preservations := buildLocalRelayPreservations(config)

	plan := RoutePlan{
		InterfaceName:           interfaceName,
		IPv4Routes:              []string{defaultIPv4Route},
		IPv6Routes:              []string{defaultIPv6Route},
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

	preservation := LocalRelayPreservation{
		EndpointHost:  endpoint.Host,
		AddressFamily: endpoint.AddressFamily,
	}
	logger.Info(
		"route plan local relay preservation represented",
		"endpoint_family",
		preservation.AddressFamily,
	)
	return []LocalRelayPreservation{preservation}
}

func localRelayHostFamily(host string) RelayAddressFamily {
	address, err := netip.ParseAddr(host)
	if err == nil && address.Is6() {
		return RelayAddressFamilyIPv6
	}
	return RelayAddressFamilyIPv4
}

func resolvedInterfaceName(config Config, interfaceName string) string {
	if interfaceName == "" {
		logger.Info("route plan using interface hint", "interface_hint", config.InterfaceNameHint)
		return config.InterfaceNameHint + "*"
	}

	logger.Info("route plan using concrete interface", "interface_name", interfaceName)
	return interfaceName
}

func buildInstallOperations(config Config, interfaceName string) []NetworkOperation {
	return []NetworkOperation{
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
		{
			Kind:          networkOperationAddIPv4Default,
			InterfaceName: interfaceName,
			Address:       defaultIPv4Route,
			AddressFamily: RelayAddressFamilyIPv4,
		},
		{
			Kind:          networkOperationAddIPv6Default,
			InterfaceName: interfaceName,
			Address:       defaultIPv6Route,
			AddressFamily: RelayAddressFamilyIPv6,
		},
	}
}

func buildRemoveOperations(interfaceName string) []NetworkOperation {
	return []NetworkOperation{
		{
			Kind:          networkOperationDeleteIPv4Default,
			InterfaceName: interfaceName,
			Address:       defaultIPv4Route,
			AddressFamily: RelayAddressFamilyIPv4,
		},
		{
			Kind:          networkOperationDeleteIPv6Default,
			InterfaceName: interfaceName,
			Address:       defaultIPv6Route,
			AddressFamily: RelayAddressFamilyIPv6,
		},
	}
}

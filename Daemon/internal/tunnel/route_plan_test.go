package tunnel

import (
	"net/netip"
	"testing"
)

func TestDefaultConfigIsDualStack(t *testing.T) {
	config := DefaultConfig()

	ipv4Address, err := netip.ParseAddr(config.IPv4Address)
	if err != nil {
		t.Fatalf("parse IPv4 address: %v", err)
	}
	if !ipv4Address.Is4() {
		t.Fatalf("IPv4 address is not IPv4: %s", config.IPv4Address)
	}

	ipv6Address, err := netip.ParseAddr(config.IPv6Address)
	if err != nil {
		t.Fatalf("parse IPv6 address: %v", err)
	}
	if !ipv6Address.Is6() {
		t.Fatalf("IPv6 address is not IPv6: %s", config.IPv6Address)
	}
}

func TestRoutePlanInstallsTypedDualStackOperations(t *testing.T) {
	config := DefaultConfig()
	config.LocalRelayEndpoint = "192.0.2.55:51820"
	plan := BuildRoutePlan(config, "utun42")

	if len(plan.IPv4Routes) != 1 || plan.IPv4Routes[0] != defaultIPv4Route {
		t.Fatalf("unexpected IPv4 routes: %#v", plan.IPv4Routes)
	}
	if len(plan.IPv6Routes) != 1 || plan.IPv6Routes[0] != defaultIPv6Route {
		t.Fatalf("unexpected IPv6 routes: %#v", plan.IPv6Routes)
	}

	expectedInstallKinds := []NetworkOperationKind{
		networkOperationIPv4Address,
		networkOperationIPv6Address,
		networkOperationInterfaceMTUAndUp,
		networkOperationAddIPv4Default,
		networkOperationAddIPv6Default,
	}
	for index, expectedKind := range expectedInstallKinds {
		if plan.InstallOperations[index].Kind != expectedKind {
			t.Fatalf("unexpected install operation at %d: %#v", index, plan.InstallOperations)
		}
		if plan.InstallOperations[index].InterfaceName != "utun42" {
			t.Fatalf("unexpected install interface at %d: %#v", index, plan.InstallOperations[index])
		}
	}

	if !hasOperationKind(plan.RemoveOperations, networkOperationDeleteIPv4Default) {
		t.Fatalf("missing IPv4 default route removal: %#v", plan.RemoveOperations)
	}
	if !hasOperationKind(plan.RemoveOperations, networkOperationDeleteIPv6Default) {
		t.Fatalf("missing IPv6 default route removal: %#v", plan.RemoveOperations)
	}
	if len(plan.LocalRelayPreservations) != 1 {
		t.Fatalf("missing local relay preservation: %#v", plan.LocalRelayPreservations)
	}
	if plan.LocalRelayPreservations[0].EndpointHost != "192.0.2.55" {
		t.Fatalf("unexpected local relay preservation: %#v", plan.LocalRelayPreservations[0])
	}
}

func hasOperationKind(operations []NetworkOperation, expected NetworkOperationKind) bool {
	for _, operation := range operations {
		if operation.Kind == expected {
			return true
		}
	}

	return false
}

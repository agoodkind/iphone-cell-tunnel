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
	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")

	if len(plan.IPv4Routes) != 1 || plan.IPv4Routes[0] != "0.0.0.0/0" {
		t.Fatalf("unexpected IPv4 routes: %#v", plan.IPv4Routes)
	}
	if len(plan.IPv6Routes) != 1 || plan.IPv6Routes[0] != "::/0" {
		t.Fatalf("unexpected IPv6 routes: %#v", plan.IPv6Routes)
	}

	expectedInstallKinds := []NetworkOperationKind{
		networkOperationIPv4Address,
		networkOperationIPv6Address,
		networkOperationInterfaceMTUAndUp,
		networkOperationAddIPv4Route,
		networkOperationAddIPv6Route,
	}
	for index, expectedKind := range expectedInstallKinds {
		if plan.InstallOperations[index].Kind != expectedKind {
			t.Fatalf("unexpected install operation at %d: %#v", index, plan.InstallOperations)
		}
		if plan.InstallOperations[index].InterfaceName != "utun42" {
			t.Fatalf("unexpected install interface at %d: %#v", index, plan.InstallOperations[index])
		}
	}

	if !hasOperationKind(plan.RemoveOperations, networkOperationDeleteIPv4Route) {
		t.Fatalf("missing IPv4 route removal: %#v", plan.RemoveOperations)
	}
	if !hasOperationKind(plan.RemoveOperations, networkOperationDeleteIPv6Route) {
		t.Fatalf("missing IPv6 route removal: %#v", plan.RemoveOperations)
	}
	if len(plan.LocalRelayPreservations) != 1 {
		t.Fatalf("missing local relay preservation: %#v", plan.LocalRelayPreservations)
	}
	if plan.LocalRelayPreservations[0].EndpointHost != "192.0.2.55" {
		t.Fatalf("unexpected local relay preservation: %#v", plan.LocalRelayPreservations[0])
	}
}

func TestRoutePlanUsesConfiguredAllowedIPs(t *testing.T) {
	config := DefaultConfig()
	wireGuardConfig := testWireGuardConfigModel()
	wireGuardConfig.Peer.AllowedIPs = []netip.Prefix{
		netip.MustParsePrefix("93.184.216.34/32"),
		netip.MustParsePrefix("2606:2800:220:1:248:1893:25c8:1946/128"),
	}

	plan := BuildRoutePlan(config, wireGuardConfig, "utun42")
	if len(plan.IPv4Routes) != 1 || plan.IPv4Routes[0] != "93.184.216.34/32" {
		t.Fatalf("unexpected IPv4 routes: %#v", plan.IPv4Routes)
	}
	if len(plan.IPv6Routes) != 1 || plan.IPv6Routes[0] != "2606:2800:220:1:248:1893:25c8:1946/128" {
		t.Fatalf("unexpected IPv6 routes: %#v", plan.IPv6Routes)
	}
}

func TestRoutePlanSkipsLoopbackRelayPreservation(t *testing.T) {
	config := DefaultConfig()
	config.LocalRelayEndpoint = "127.0.0.1:45787"

	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")
	if len(plan.LocalRelayPreservations) != 0 {
		t.Fatalf("unexpected local relay preservations: %#v", plan.LocalRelayPreservations)
	}
}

func TestRoutePlanPreservesScopedIPv6RelayEndpoint(t *testing.T) {
	config := DefaultConfig()
	config.LocalRelayEndpoint = "[fe80::1%en11]:57400"

	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")
	if len(plan.LocalRelayPreservations) != 1 {
		t.Fatalf("unexpected local relay preservations: %#v", plan.LocalRelayPreservations)
	}
	preservation := plan.LocalRelayPreservations[0]
	if preservation.EndpointHost != "fe80::1" {
		t.Fatalf("unexpected scoped relay host: %#v", preservation)
	}
	if preservation.EndpointInterface != "en11" {
		t.Fatalf("unexpected scoped relay interface: %#v", preservation)
	}
}

func TestRoutePlanSkipsUnscopedIPv6LinkLocalRelayPreservation(t *testing.T) {
	config := DefaultConfig()
	config.LocalRelayEndpoint = "[fe80::1]:57400"

	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")
	if len(plan.LocalRelayPreservations) != 0 {
		t.Fatalf("unexpected unscoped local relay preservation: %#v", plan.LocalRelayPreservations)
	}
}

func testWireGuardConfigModel() WireGuardConfig {
	return WireGuardConfig{
		Peer: WireGuardPeerConfig{
			AllowedIPs: []netip.Prefix{
				netip.MustParsePrefix("0.0.0.0/0"),
				netip.MustParsePrefix("::/0"),
			},
		},
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

package tunnel

import (
	"net/netip"
	"strings"
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

func TestRoutePlanInstallsDualStackDefaultRoutes(t *testing.T) {
	config := DefaultConfig()
	plan := BuildRoutePlan(config, "utun42")

	if len(plan.IPv4Routes) != 1 || plan.IPv4Routes[0] != defaultIPv4Route {
		t.Fatalf("unexpected IPv4 routes: %#v", plan.IPv4Routes)
	}
	if len(plan.IPv6Routes) != 1 || plan.IPv6Routes[0] != defaultIPv6Route {
		t.Fatalf("unexpected IPv6 routes: %#v", plan.IPv6Routes)
	}

	if !hasCommand(plan.InstallCommands, "route -n add -inet default -interface utun42") {
		t.Fatalf("missing IPv4 install command: %#v", plan.InstallCommands)
	}
	if !hasCommand(plan.InstallCommands, "route -n add -inet6 default -interface utun42") {
		t.Fatalf("missing IPv6 install command: %#v", plan.InstallCommands)
	}
	if !hasCommand(plan.RemoveCommands, "route -n delete -inet default -interface utun42") {
		t.Fatalf("missing IPv4 restore command: %#v", plan.RemoveCommands)
	}
	if !hasCommand(plan.RemoveCommands, "route -n delete -inet6 default -interface utun42") {
		t.Fatalf("missing IPv6 restore command: %#v", plan.RemoveCommands)
	}
}

func TestDescribePlanIncludesDryRunCommands(t *testing.T) {
	description := DescribePlan(DefaultConfig())

	expectedFragments := []string{
		"ipv4=198.18.0.2/15 route=0.0.0.0/0",
		"ipv6=fd7a:ce11:7a11::2/64 route=::/0",
		"install=route -n add -inet default -interface utun*",
		"install=route -n add -inet6 default -interface utun*",
		"restore=route -n delete -inet default -interface utun*",
		"restore=route -n delete -inet6 default -interface utun*",
	}

	for _, expectedFragment := range expectedFragments {
		if !strings.Contains(description, expectedFragment) {
			t.Fatalf("dry-run plan missing %q:\n%s", expectedFragment, description)
		}
	}
}

func TestIPv4Netmask(t *testing.T) {
	netmask := IPv4Netmask(15)
	if netmask != "255.254.0.0" {
		t.Fatalf("unexpected netmask: %s", netmask)
	}
}

func hasCommand(commands []RouteCommand, expected string) bool {
	for _, command := range commands {
		if command.String() == expected {
			return true
		}
	}

	return false
}

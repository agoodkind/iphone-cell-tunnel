package tunnel

import (
	"errors"
	"fmt"
	"runtime"
	"strings"
)

// Config describes the local tunnel interface and route shape.
type Config struct {
	InterfaceNameHint string
	MTU               int
	IPv4Address       string
	IPv4PeerAddress   string
	IPv4PrefixLength  int
	IPv6Address       string
	IPv6PrefixLength  int
	ServiceType       string
}

// RuntimeStatus describes the daemon-visible state of the tunnel.
type RuntimeStatus struct {
	Running     bool
	RouteState  string
	PeerState   string
	IPv4Address string
	IPv6Address string
}

// EnvironmentCheck records one local prerequisite probe.
type EnvironmentCheck struct {
	Name  string
	Value string
}

// DefaultConfig returns the current internal IPv4 and IPv6 tunnel defaults.
func DefaultConfig() Config {
	logger.Debug("building default tunnel config")
	return Config{
		InterfaceNameHint: "utun",
		MTU:               1280,
		IPv4Address:       "198.18.0.2",
		IPv4PeerAddress:   "198.18.0.1",
		IPv4PrefixLength:  15,
		IPv6Address:       "fd7a:ce11:7a11::2",
		IPv6PrefixLength:  64,
		ServiceType:       "_cellrelay._tcp",
	}
}

// DescribePlan renders a dry-run route plan for user-facing CLI output.
func DescribePlan(config Config) string {
	logger.Info("describing tunnel route plan", "interface_hint", config.InterfaceNameHint)
	routePlan := BuildRoutePlan(config, "")
	lines := []string{
		"running=false dry_run=true",
		fmt.Sprintf("interface=%s mtu=%d", routePlan.InterfaceName, config.MTU),
		fmt.Sprintf("ipv4=%s/%d route=0.0.0.0/0", config.IPv4Address, config.IPv4PrefixLength),
		fmt.Sprintf("ipv6=%s/%d route=::/0", config.IPv6Address, config.IPv6PrefixLength),
		"service=" + config.ServiceType,
		"routes=not-installed",
	}
	for _, command := range routePlan.InstallCommands {
		lines = append(lines, "install="+command.String())
	}
	for _, command := range routePlan.RemoveCommands {
		lines = append(lines, "restore="+command.String())
	}
	logger.Info(
		"tunnel route plan described",
		"install_commands",
		len(routePlan.InstallCommands),
		"remove_commands",
		len(routePlan.RemoveCommands),
	)
	return strings.Join(lines, "\n")
}

// Status returns the daemon-visible tunnel state.
func Status() RuntimeStatus {
	logger.Info("reading tunnel runtime status")
	config := DefaultConfig()
	status := RuntimeStatus{
		Running:     false,
		RouteState:  "not-installed",
		PeerState:   "not-paired",
		IPv4Address: config.IPv4Address,
		IPv6Address: config.IPv6Address,
	}
	logger.Info("tunnel runtime status resolved", "running", status.Running, "routes", status.RouteState)
	return status
}

// CheckEnvironment reports local prerequisites needed before route mutation.
func CheckEnvironment() []EnvironmentCheck {
	logger.Info("checking tunnel daemon environment", "os", runtime.GOOS, "arch", runtime.GOARCH)
	checks := []EnvironmentCheck{
		{Name: "os", Value: runtime.GOOS},
		{Name: "arch", Value: runtime.GOARCH},
		{Name: "utun", Value: checkUTUNSupport()},
		{Name: "privileged_route_changes", Value: "deferred"},
		{Name: "netstack", Value: "deferred"},
	}
	logger.Info("tunnel daemon environment checked", "check_count", len(checks))
	return checks
}

// Start applies tunnel interface and route state.
func Start(config Config) error {
	err := fmt.Errorf("privileged tunnel activation is not implemented yet for %s", config.InterfaceNameHint)
	logger.Error("tunnel start unavailable", "err", err, "interface_hint", config.InterfaceNameHint)
	return err
}

// Stop restores route state after tunnel shutdown.
func Stop() error {
	err := errors.New("route restore is not implemented yet")
	logger.Error("tunnel stop unavailable", "err", err)
	return err
}

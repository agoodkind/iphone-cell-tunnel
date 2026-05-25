package tunnel

import (
	"context"
	"net/netip"
	"runtime"
	"strings"
)

// Config describes the local tunnel interface and route shape.
type Config struct {
	InterfaceNameHint   string
	MTU                 int
	IPv4Address         string
	IPv4PeerAddress     string
	IPv4PrefixLength    int
	IPv6Address         string
	IPv6PrefixLength    int
	ServiceType         string
	WireGuardConfigPath string
	LocalRelayEndpoint  string
}

// StartOptions carries the runtime-only values supplied by a Mac app start request.
type StartOptions struct {
	WireGuardConfigPath string `json:"wireGuardConfigPath"`
	LocalRelayEndpoint  string `json:"localRelayEndpoint"`
}

// RuntimeStatus describes the daemon-visible state of the tunnel.
type RuntimeStatus struct {
	Running     bool   `json:"running"`
	RouteState  string `json:"routeState"`
	PeerState   string `json:"peerState"`
	IPv4Address string `json:"ipv4Address"`
	IPv6Address string `json:"ipv6Address"`
	LastError   string `json:"lastError,omitempty"`
}

// EnvironmentCheck records one local prerequisite probe.
type EnvironmentCheck struct {
	Name  string `json:"name"`
	Value string `json:"value"`
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

// ConfigWithStartOptions applies typed start options to the default tunnel shape.
func ConfigWithStartOptions(options StartOptions) (Config, error) {
	if err := options.Validate(); err != nil {
		return Config{}, err
	}

	config := DefaultConfig()
	config.WireGuardConfigPath = strings.TrimSpace(options.WireGuardConfigPath)
	config.LocalRelayEndpoint = strings.TrimSpace(options.LocalRelayEndpoint)
	logger.Info(
		"start options applied to tunnel config",
		"wireguard_config_path_configured",
		config.WireGuardConfigPath != "",
		"local_relay_endpoint_configured",
		config.LocalRelayEndpoint != "",
	)
	return config, nil
}

// ConfigWithWireGuardConfig applies interface addresses from the WireGuard config onto the
// local utun shape so inner packet source addresses match the hosted server expectations.
func ConfigWithWireGuardConfig(config Config, wireGuardConfig WireGuardConfig) Config {
	hasIPv4Address := false
	hasIPv6Address := false

	for _, addressPrefix := range wireGuardConfig.Interface.Addresses {
		address := addressPrefix.Addr()
		if address.Is4() && !hasIPv4Address {
			config.IPv4Address = address.String()
			config.IPv4PeerAddress = pointToPointPeerAddress(addressPrefix)
			config.IPv4PrefixLength = addressPrefix.Bits()
			hasIPv4Address = true
			continue
		}
		if address.Is6() && !hasIPv6Address {
			config.IPv6Address = address.String()
			config.IPv6PrefixLength = addressPrefix.Bits()
			hasIPv6Address = true
		}
	}

	logger.Info(
		"wireguard interface addresses applied",
		"ipv4_configured",
		hasIPv4Address,
		"ipv6_configured",
		hasIPv6Address,
	)
	return config
}

// Validate checks that a typed start request includes the runtime inputs the daemon needs.
func (options StartOptions) Validate() error {
	if strings.TrimSpace(options.WireGuardConfigPath) == "" {
		logger.Error("start options validation failed", "err", ErrWireGuardConfigPathMissing)
		return ErrWireGuardConfigPathMissing
	}
	if strings.TrimSpace(options.LocalRelayEndpoint) == "" {
		logger.Error("start options validation failed", "err", ErrLocalRelayEndpointMissing)
		return ErrLocalRelayEndpointMissing
	}
	logger.Info("start options validation completed")
	return nil
}

// Status returns the daemon-visible tunnel state.
func Status() RuntimeStatus {
	logger.Info("reading tunnel runtime status")
	config := DefaultConfig()
	runtimeMutex.Lock()
	running := activeRuntime != nil
	routesInstalled := running && activeRuntime.routesInstalled
	if activeRuntime != nil {
		config = activeRuntime.config
	}
	lastError := lastRuntimeError
	runtimeMutex.Unlock()
	routeState := "not-installed"
	if routesInstalled {
		routeState = "installed"
	}
	status := RuntimeStatus{
		Running:     running,
		RouteState:  routeState,
		PeerState:   peerState(running),
		IPv4Address: config.IPv4Address,
		IPv6Address: config.IPv6Address,
		LastError:   lastError,
	}
	logger.Info("tunnel runtime status resolved", "running", status.Running, "routes", status.RouteState)
	return status
}

func pointToPointPeerAddress(prefix netip.Prefix) string {
	return prefix.Addr().String()
}

// CheckEnvironment reports local prerequisites needed before route mutation.
func CheckEnvironment() []EnvironmentCheck {
	logger.Info("checking tunnel daemon environment", "os", runtime.GOOS, "arch", runtime.GOARCH)
	checks := []EnvironmentCheck{
		{Name: "os", Value: runtime.GOOS},
		{Name: "arch", Value: runtime.GOARCH},
		{Name: "utun", Value: checkUTUNSupport()},
		{Name: "privileged_route_changes", Value: "requires-privileged-daemon"},
		{Name: "wireguard_runtime", Value: "available"},
	}
	logger.Info("tunnel daemon environment checked", "check_count", len(checks))
	return checks
}

// Start applies tunnel interface and route state.
func Start(config Config) error {
	logger.Info("tunnel start requested", "interface_hint", config.InterfaceNameHint)
	runtimeMutex.Lock()
	defer runtimeMutex.Unlock()

	if activeRuntime != nil {
		logger.Info("tunnel start ignored because runtime is already active")
		return nil
	}

	lastRuntimeError = ""
	wireGuardRuntime, err := NewWireGuardRuntime(config)
	if err != nil {
		lastRuntimeError = err.Error()
		logger.Error("tunnel runtime configuration failed", "err", err)
		return err
	}
	if err := wireGuardRuntime.Start(context.Background()); err != nil {
		lastRuntimeError = err.Error()
		logger.Error("tunnel runtime start failed", "err", err)
		return err
	}
	activeRuntime = wireGuardRuntime
	logger.Info("tunnel start completed")
	return nil
}

// Stop restores route state after tunnel shutdown.
func Stop() error {
	logger.Info("tunnel stop requested")
	runtimeMutex.Lock()
	defer runtimeMutex.Unlock()

	if activeRuntime == nil {
		logger.Info("tunnel stop ignored because runtime is not active")
		return nil
	}

	activeRuntime.Stop(context.Background())
	activeRuntime = nil
	logger.Info("tunnel stop completed")
	return nil
}

func peerState(running bool) string {
	if running {
		return "wireguard-configured"
	}
	return "not-paired"
}

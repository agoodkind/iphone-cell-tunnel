package tunnel

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"

	wgdevice "golang.zx2c4.com/wireguard/device"
	wgtun "golang.zx2c4.com/wireguard/tun"
)

// WireGuardRuntime owns the local wireguard-go device, utun, and relay bind lifecycle.
type WireGuardRuntime struct {
	config          Config
	wireGuardConfig WireGuardConfig
	routePlan       RoutePlan
	relayBind       *RelayDatagramBind
	relayClient     *TCPRelayClient
	routeExecutor   RouteExecutor
	tunDevice       wgtun.Device
	device          *wgdevice.Device
	cancel          context.CancelFunc
	stopOnce        sync.Once
	routesInstalled bool
}

var (
	errRuntimeRelayDisconnected = errors.New("relay connection disconnected")
	runtimeMutex                sync.Mutex
	activeRuntime               *WireGuardRuntime
	lastRuntimeError            string
)

// NewWireGuardRuntime parses runtime configuration and wires the relay bind to the relay client.
func NewWireGuardRuntime(config Config) (*WireGuardRuntime, error) {
	if config.WireGuardConfigPath == "" {
		return nil, ErrWireGuardConfigPathMissing
	}
	if config.LocalRelayEndpoint == "" {
		return nil, ErrLocalRelayEndpointMissing
	}

	wireGuardConfig, err := LoadWireGuardConfig(config.WireGuardConfigPath)
	if err != nil {
		return nil, err
	}
	config = ConfigWithWireGuardConfig(config, wireGuardConfig)
	relayBind := NewRelayDatagramBind(nil)
	relayClient, err := buildRelayClient(config.LocalRelayEndpoint, wireGuardConfig.Peer.Endpoint, relayBind)
	if err != nil {
		return nil, err
	}
	relayBind.SetSink(relayClient)

	runtime := &WireGuardRuntime{
		config:          config,
		wireGuardConfig: wireGuardConfig,
		relayBind:       relayBind,
		relayClient:     relayClient,
		routeExecutor:   NewRouteExecutor(DarwinNetworkManager{}),
	}
	relayClient.SetDisconnectHandler(runtime.handleRelayDisconnect)
	logger.Info(
		"wireguard runtime configured",
		"local_relay_configured",
		config.LocalRelayEndpoint != "",
		"wireguard_config_path_configured",
		config.WireGuardConfigPath != "",
		"server_endpoint_family",
		wireGuardConfig.Peer.Endpoint.AddressFamily,
	)
	return runtime, nil
}

// Start opens the local relay, creates utun, configures wireguard-go, and brings the device up.
func (runtime *WireGuardRuntime) Start(parentContext context.Context) error {
	runContext, cancel := context.WithCancel(parentContext)
	runtime.cancel = cancel

	logger.InfoContext(parentContext, "wireguard runtime starting")
	if err := runtime.relayClient.Start(runContext); err != nil {
		cancel()
		logger.ErrorContext(parentContext, "wireguard runtime relay start failed", "err", err)
		return fmt.Errorf("start relay client: %w", err)
	}

	tunDevice, err := wgtun.CreateTUN(runtime.config.InterfaceNameHint, runtime.config.MTU)
	if err != nil {
		cancel()
		if closeErr := runtime.relayClient.Close(); closeErr != nil {
			logger.ErrorContext(parentContext, "wireguard runtime relay close after tun create failure failed", "err", closeErr)
		}
		logger.ErrorContext(parentContext, "wireguard runtime tun create failed", "err", err)
		return fmt.Errorf("create wireguard tun: %w", err)
	}
	runtime.tunDevice = tunDevice

	interfaceName, err := tunDevice.Name()
	if err != nil {
		cancel()
		if closeErr := runtime.relayClient.Close(); closeErr != nil {
			logger.ErrorContext(parentContext, "wireguard runtime relay close after tun name failure failed", "err", closeErr)
		}
		if closeErr := tunDevice.Close(); closeErr != nil {
			logger.ErrorContext(parentContext, "wireguard runtime tun close after name failure failed", "err", closeErr)
		}
		logger.ErrorContext(parentContext, "wireguard runtime tun name failed", "err", err)
		return fmt.Errorf("read wireguard tun name: %w", err)
	}
	runtime.routePlan = BuildRoutePlan(runtime.config, runtime.wireGuardConfig, interfaceName)
	logger.InfoContext(
		parentContext,
		"wireguard runtime route plan prepared",
		"interface_name",
		interfaceName,
		"install_operations",
		len(runtime.routePlan.InstallOperations),
		"local_relay_preservations",
		len(runtime.routePlan.LocalRelayPreservations),
	)
	if err := runtime.routeExecutor.Install(runContext, runtime.routePlan); err != nil {
		cancel()
		if closeErr := runtime.relayClient.Close(); closeErr != nil {
			logger.ErrorContext(parentContext, "wireguard runtime relay close after route install failure failed", "err", closeErr)
		}
		if closeErr := tunDevice.Close(); closeErr != nil {
			logger.ErrorContext(parentContext, "wireguard runtime tun close after route install failure failed", "err", closeErr)
		}
		logger.ErrorContext(parentContext, "wireguard runtime route install failed", "err", err)
		return fmt.Errorf("install tunnel routes: %w", err)
	}
	runtime.routesInstalled = true

	runtime.device = wgdevice.NewDevice(tunDevice, runtime.relayBind, wgdevice.NewLogger(wgdevice.LogLevelSilent, ""))
	if err := runtime.device.IpcSetOperation(strings.NewReader(runtime.wireGuardConfig.UAPIConfig())); err != nil {
		runtime.Stop(parentContext)
		logger.ErrorContext(parentContext, "wireguard runtime ipc set failed", "err", err)
		return fmt.Errorf("configure wireguard device: %w", err)
	}
	if err := runtime.device.Up(); err != nil {
		runtime.Stop(parentContext)
		logger.ErrorContext(parentContext, "wireguard runtime device up failed", "err", err)
		return fmt.Errorf("bring wireguard device up: %w", err)
	}

	logger.InfoContext(parentContext, "wireguard runtime started", "interface_name", interfaceName)
	return nil
}

// Stop closes the wireguard-go runtime and relay connection.
func (runtime *WireGuardRuntime) Stop(ctx context.Context) {
	runtime.stopOnce.Do(func() {
		logger.InfoContext(ctx, "wireguard runtime stopping")
		if runtime.cancel != nil {
			runtime.cancel()
		}
		if runtime.routesInstalled {
			if err := runtime.routeExecutor.Remove(ctx, runtime.routePlan); err != nil {
				logger.ErrorContext(ctx, "wireguard runtime route removal failed", "err", err)
			}
			runtime.routesInstalled = false
		}
		if runtime.device != nil {
			runtime.device.Close()
		} else if runtime.tunDevice != nil {
			if err := runtime.tunDevice.Close(); err != nil {
				logger.ErrorContext(ctx, "wireguard runtime tun close failed", "err", err)
			}
		}
		if runtime.relayClient != nil {
			if err := runtime.relayClient.Close(); err != nil {
				logger.ErrorContext(ctx, "wireguard runtime relay close failed", "err", err)
			}
		}
		logger.InfoContext(ctx, "wireguard runtime stopped")
	})
}

func (runtime *WireGuardRuntime) handleRelayDisconnect(err error) {
	if err == nil {
		err = errRuntimeRelayDisconnected
	}
	logger.Error("wireguard runtime relay disconnected", "err", err)
	stopActiveRuntimeAfterFailure(runtime, fmt.Errorf("relay disconnected: %w", err))
}

func stopActiveRuntimeAfterFailure(runtime *WireGuardRuntime, err error) {
	runtimeMutex.Lock()
	if activeRuntime != runtime {
		runtimeMutex.Unlock()
		logger.Info("runtime failure ignored because runtime is no longer active")
		return
	}
	activeRuntime = nil
	lastRuntimeError = err.Error()
	runtimeMutex.Unlock()

	runtime.Stop(context.Background())
}

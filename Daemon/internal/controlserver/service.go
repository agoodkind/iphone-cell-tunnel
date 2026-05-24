// Package controlserver implements the typed gRPC control plane for celltunneld.
package controlserver

import (
	"celltunnel/daemon/internal/discovery"
	"celltunnel/daemon/internal/tunnel"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"

	controlv1 "celltunnel/daemon/internal/controlv1"

	"google.golang.org/grpc/peer"
)

var controlLogger = slog.Default().With("component", "controlserver")

// TunnelRuntime abstracts daemon-owned tunnel lifecycle operations for RPC tests.
type TunnelRuntime interface {
	Status() tunnel.RuntimeStatus
	CheckEnvironment() []tunnel.EnvironmentCheck
	Start(tunnel.StartOptions) error
	Stop() error
}

// RelayDiscovery abstracts daemon-owned relay discovery operations for RPC tests.
type RelayDiscovery interface {
	Start() error
	Stop() error
	Snapshot() discovery.Snapshot
	SelectService(serviceID string) error
	SelectedEndpoint() (discovery.Endpoint, bool)
}

// Service implements the typed gRPC control plane.
type Service struct {
	controlv1.UnimplementedTunnelControlServiceServer

	tunnelRuntime TunnelRuntime
	relayManager  RelayDiscovery

	mutex               sync.Mutex
	activeRelayEndpoint *discovery.Endpoint
}

// NewService builds a TunnelControlService implementation from explicit dependencies.
func NewService(tunnelRuntime TunnelRuntime, relayManager RelayDiscovery) *Service {
	return &Service{
		tunnelRuntime: tunnelRuntime,
		relayManager:  relayManager,
	}
}

// NewDefaultService builds a TunnelControlService implementation using production dependencies.
func NewDefaultService() *Service {
	return NewService(tunnelRuntimeAdapter{}, discovery.NewManager())
}

// Shutdown stops discovery and tunnel runtime during daemon process teardown.
func (service *Service) Shutdown() error {
	service.mutex.Lock()
	service.activeRelayEndpoint = nil
	service.mutex.Unlock()

	stopError := service.relayManager.Stop()
	shutdownError := errors.Join(stopError, service.tunnelRuntime.Stop())
	if shutdownError == nil {
		return nil
	}

	slog.Error("control service shutdown failed", "err", shutdownError)
	return fmt.Errorf("shutdown control service: %w", shutdownError)
}

// Status returns the daemon runtime snapshot over typed IPC.
func (service *Service) Status(
	contextValue context.Context,
	_ *controlv1.StatusRequest,
) (*controlv1.StatusResponse, error) {
	logger := controlLogger
	if peerValue, ok := peer.FromContext(contextValue); ok && peerValue.Addr != nil {
		logger = logger.With("peer_addr", formatAddress(peerValue.Addr))
	}
	logger.InfoContext(contextValue, "status rpc requested")
	status := service.buildDaemonStatus()
	logger.InfoContext(
		contextValue,
		"status rpc completed",
		"running",
		status.GetRunning(),
		"route_state",
		status.GetRoute().GetState(),
	)
	return &controlv1.StatusResponse{
		Result: &controlv1.StatusResponse_Status{
			Status: status,
		},
	}, nil
}

// Check returns the daemon environment report over typed IPC.
func (service *Service) Check(
	contextValue context.Context,
	_ *controlv1.CheckRequest,
) (*controlv1.CheckResponse, error) {
	logger := controlLogger
	if peerValue, ok := peer.FromContext(contextValue); ok && peerValue.Addr != nil {
		logger = logger.With("peer_addr", formatAddress(peerValue.Addr))
	}
	logger.InfoContext(contextValue, "check rpc requested")
	report := &controlv1.EnvironmentReport{
		Checks: make([]*controlv1.EnvironmentCheck, 0),
	}
	for _, check := range service.tunnelRuntime.CheckEnvironment() {
		report.Checks = append(report.Checks, &controlv1.EnvironmentCheck{
			Name:  check.Name,
			Value: check.Value,
		})
	}
	logger.InfoContext(contextValue, "check rpc completed", "check_count", len(report.GetChecks()))
	return &controlv1.CheckResponse{
		Result: &controlv1.CheckResponse_Report{
			Report: report,
		},
	}, nil
}

// StartTunnel starts the daemon-owned tunnel runtime.
func (service *Service) StartTunnel(
	contextValue context.Context,
	request *controlv1.StartTunnelRequest,
) (*controlv1.StartTunnelResponse, error) {
	logger := controlLogger
	if peerValue, ok := peer.FromContext(contextValue); ok && peerValue.Addr != nil {
		logger = logger.With("peer_addr", formatAddress(peerValue.Addr))
	}
	logger.InfoContext(contextValue, "start tunnel rpc requested")
	settings := request.GetSettings()
	if settings == nil || strings.TrimSpace(settings.GetWireGuardConfigPath()) == "" {
		logger.InfoContext(contextValue, "start tunnel rpc rejected missing config path")
		return startErrorResponse(
			controlv1.ControlErrorCode_CONTROL_ERROR_CODE_MISSING_WIREGUARD_CONFIG_PATH,
			"missing WireGuard config path",
		), nil
	}

	relayEndpoint, err := service.resolveRelayEndpoint(settings.GetRelayEndpoint())
	if err != nil {
		logger.InfoContext(contextValue, "start tunnel rpc rejected relay resolution", "err", err)
		return startErrorResponse(controlErrorCodeForError(err), err.Error()), nil
	}

	previousStatus := service.tunnelRuntime.Status()
	err = service.tunnelRuntime.Start(tunnel.StartOptions{
		WireGuardConfigPath: strings.TrimSpace(settings.GetWireGuardConfigPath()),
		LocalRelayEndpoint:  relayEndpoint.SocketAddress(),
	})
	if err != nil {
		logger.ErrorContext(contextValue, "start tunnel rpc runtime start failed", "err", err)
		return startErrorResponse(
			controlv1.ControlErrorCode_CONTROL_ERROR_CODE_RUNTIME_START_FAILURE,
			err.Error(),
		), nil
	}

	if !previousStatus.Running {
		service.mutex.Lock()
		selected := relayEndpoint
		service.activeRelayEndpoint = &selected
		service.mutex.Unlock()
	}

	logger.InfoContext(contextValue, "start tunnel rpc completed", "relay_endpoint", relayEndpoint.SocketAddress())
	return &controlv1.StartTunnelResponse{
		Result: &controlv1.StartTunnelResponse_Status{
			Status: service.buildDaemonStatus(),
		},
	}, nil
}

// StopTunnel stops the daemon-owned tunnel runtime.
func (service *Service) StopTunnel(
	contextValue context.Context,
	_ *controlv1.StopTunnelRequest,
) (*controlv1.StopTunnelResponse, error) {
	logger := controlLogger
	if peerValue, ok := peer.FromContext(contextValue); ok && peerValue.Addr != nil {
		logger = logger.With("peer_addr", formatAddress(peerValue.Addr))
	}
	logger.InfoContext(contextValue, "stop tunnel rpc requested")
	if err := service.tunnelRuntime.Stop(); err != nil {
		logger.ErrorContext(contextValue, "stop tunnel rpc failed", "err", err)
		return &controlv1.StopTunnelResponse{
			Result: &controlv1.StopTunnelResponse_Error{
				Error: controlError(
					controlv1.ControlErrorCode_CONTROL_ERROR_CODE_INTERNAL,
					err.Error(),
				),
			},
		}, nil
	}

	service.mutex.Lock()
	service.activeRelayEndpoint = nil
	service.mutex.Unlock()

	logger.InfoContext(contextValue, "stop tunnel rpc completed")
	return &controlv1.StopTunnelResponse{
		Result: &controlv1.StopTunnelResponse_Status{
			Status: service.buildDaemonStatus(),
		},
	}, nil
}

// StartRelayDiscovery starts the daemon-owned DNS-SD discovery loop.
func (service *Service) StartRelayDiscovery(
	contextValue context.Context,
	_ *controlv1.StartRelayDiscoveryRequest,
) (*controlv1.StartRelayDiscoveryResponse, error) {
	logger := controlLogger
	if peerValue, ok := peer.FromContext(contextValue); ok && peerValue.Addr != nil {
		logger = logger.With("peer_addr", formatAddress(peerValue.Addr))
	}
	logger.InfoContext(contextValue, "start relay discovery rpc requested")
	if err := service.relayManager.Start(); err != nil {
		logger.ErrorContext(contextValue, "start relay discovery rpc failed", "err", err)
		return discoveryErrorResponse(
			controlv1.ControlErrorCode_CONTROL_ERROR_CODE_DISCOVERY_UNAVAILABLE,
			err.Error(),
		), nil
	}
	snapshot := service.relayManager.Snapshot()
	logger.InfoContext(contextValue, "start relay discovery rpc completed", "phase", snapshot.Phase)
	return &controlv1.StartRelayDiscoveryResponse{
		Result: &controlv1.StartRelayDiscoveryResponse_Discovery{
			Discovery: service.discoverySnapshotToProto(snapshot),
		},
	}, nil
}

// StopRelayDiscovery stops the daemon-owned DNS-SD discovery loop.
func (service *Service) StopRelayDiscovery(
	contextValue context.Context,
	_ *controlv1.StopRelayDiscoveryRequest,
) (*controlv1.StopRelayDiscoveryResponse, error) {
	logger := controlLogger
	if peerValue, ok := peer.FromContext(contextValue); ok && peerValue.Addr != nil {
		logger = logger.With("peer_addr", formatAddress(peerValue.Addr))
	}
	logger.InfoContext(contextValue, "stop relay discovery rpc requested")
	if err := service.relayManager.Stop(); err != nil {
		logger.ErrorContext(contextValue, "stop relay discovery rpc failed", "err", err)
		return stopDiscoveryErrorResponse(
			controlv1.ControlErrorCode_CONTROL_ERROR_CODE_DISCOVERY_UNAVAILABLE,
			err.Error(),
		), nil
	}
	snapshot := service.relayManager.Snapshot()
	logger.InfoContext(contextValue, "stop relay discovery rpc completed", "phase", snapshot.Phase)
	return &controlv1.StopRelayDiscoveryResponse{
		Result: &controlv1.StopRelayDiscoveryResponse_Discovery{
			Discovery: service.discoverySnapshotToProto(snapshot),
		},
	}, nil
}

// ListRelayServices returns the daemon-owned relay discovery snapshot.
func (service *Service) ListRelayServices(
	contextValue context.Context,
	_ *controlv1.ListRelayServicesRequest,
) (*controlv1.ListRelayServicesResponse, error) {
	snapshot := service.relayManager.Snapshot()
	logger := controlLogger
	if peerValue, ok := peer.FromContext(contextValue); ok && peerValue.Addr != nil {
		logger = logger.With("peer_addr", formatAddress(peerValue.Addr))
	}
	logger.InfoContext(
		contextValue,
		"list relay services rpc requested",
		"phase",
		snapshot.Phase,
		"service_count",
		len(snapshot.Services),
	)
	return &controlv1.ListRelayServicesResponse{
		Result: &controlv1.ListRelayServicesResponse_Discovery{
			Discovery: service.discoverySnapshotToProto(snapshot),
		},
	}, nil
}

// SelectRelayService updates the daemon-owned selected relay service.
func (service *Service) SelectRelayService(
	contextValue context.Context,
	request *controlv1.SelectRelayServiceRequest,
) (*controlv1.SelectRelayServiceResponse, error) {
	logger := controlLogger
	if peerValue, ok := peer.FromContext(contextValue); ok && peerValue.Addr != nil {
		logger = logger.With("peer_addr", formatAddress(peerValue.Addr))
	}
	serviceID := strings.TrimSpace(request.GetServiceId())
	logger.InfoContext(contextValue, "select relay service rpc requested", "service_id", serviceID)
	if serviceID == "" {
		logger.InfoContext(contextValue, "select relay service rpc rejected empty service id")
		return selectDiscoveryErrorResponse(
			controlv1.ControlErrorCode_CONTROL_ERROR_CODE_RELAY_SERVICE_NOT_FOUND,
			"relay service not found",
		), nil
	}
	if err := service.relayManager.SelectService(serviceID); err != nil {
		logger.ErrorContext(contextValue, "select relay service rpc failed", "service_id", serviceID, "err", err)
		return selectDiscoveryErrorResponse(
			controlv1.ControlErrorCode_CONTROL_ERROR_CODE_RELAY_SERVICE_NOT_FOUND,
			err.Error(),
		), nil
	}
	snapshot := service.relayManager.Snapshot()
	logger.InfoContext(contextValue, "select relay service rpc completed", "service_id", serviceID)
	return &controlv1.SelectRelayServiceResponse{
		Result: &controlv1.SelectRelayServiceResponse_Discovery{
			Discovery: service.discoverySnapshotToProto(snapshot),
		},
	}, nil
}

func (service *Service) resolveRelayEndpoint(explicit *controlv1.RelayEndpoint) (discovery.Endpoint, error) {
	if explicit != nil {
		return relayEndpointFromProto(explicit)
	}

	selectedEndpoint, ok := service.relayManager.SelectedEndpoint()
	if !ok {
		return discovery.Endpoint{}, errRelaySelectionRequired
	}
	return selectedEndpoint, nil
}

func (service *Service) buildDaemonStatus() *controlv1.DaemonStatus {
	status := service.tunnelRuntime.Status()
	relaySnapshot := service.relayManager.Snapshot()

	service.mutex.Lock()
	activeRelayEndpoint := cloneDiscoveryEndpoint(service.activeRelayEndpoint)
	service.mutex.Unlock()

	return &controlv1.DaemonStatus{
		Running: status.Running,
		Route: &controlv1.RouteStateSnapshot{
			State: routeStateFromString(status.RouteState),
		},
		Peer: &controlv1.PeerStateSnapshot{
			State: peerStateFromStatus(status.Running, relaySnapshot.SelectedEndpoint != nil),
		},
		Ipv4Address:         status.IPv4Address,
		Ipv6Address:         status.IPv6Address,
		LastError:           runtimeErrorToProto(status.LastError),
		Discovery:           service.discoverySnapshotToProto(relaySnapshot),
		ActiveRelayEndpoint: relayEndpointToProto(activeRelayEndpoint),
	}
}

func (service *Service) discoverySnapshotToProto(snapshot discovery.Snapshot) *controlv1.DiscoveryState {
	protoServices := make([]*controlv1.RelayService, 0, len(snapshot.Services))
	for _, relayService := range snapshot.Services {
		endpoints := make([]*controlv1.RelayEndpoint, 0, len(relayService.Endpoints))
		for _, endpoint := range relayService.Endpoints {
			endpoints = append(endpoints, relayEndpointToProto(&endpoint))
		}
		protoServices = append(protoServices, &controlv1.RelayService{
			Identity: &controlv1.RelayServiceIdentity{
				ServiceId:      relayService.Identity.ServiceID,
				ServiceName:    relayService.Identity.ServiceName,
				ServiceType:    relayService.Identity.ServiceType,
				Domain:         relayService.Identity.Domain,
				InterfaceIndex: relayService.Identity.InterfaceIndex,
			},
			HostName:          relayService.HostName,
			Endpoints:         endpoints,
			PreferredEndpoint: relayEndpointToProto(relayService.PreferredEndpoint),
			IsSelected:        relayService.IsSelected,
		})
	}
	return &controlv1.DiscoveryState{
		Phase:             discoveryPhaseToProto(snapshot.Phase),
		Services:          protoServices,
		SelectedServiceId: snapshot.SelectedServiceID,
		SelectedEndpoint:  relayEndpointToProto(snapshot.SelectedEndpoint),
		LastError:         runtimeErrorToProto(snapshot.LastError),
	}
}

type tunnelRuntimeAdapter struct{}

func (tunnelRuntimeAdapter) Status() tunnel.RuntimeStatus {
	return tunnel.Status()
}

func (tunnelRuntimeAdapter) CheckEnvironment() []tunnel.EnvironmentCheck {
	return tunnel.CheckEnvironment()
}

func (tunnelRuntimeAdapter) Start(options tunnel.StartOptions) error {
	config, err := tunnel.ConfigWithStartOptions(options)
	if err != nil {
		controlLogger.Error("build tunnel config from start options failed", "err", err)
		return fmt.Errorf("build tunnel config from start options: %w", err)
	}
	if err := tunnel.Start(config); err != nil {
		controlLogger.Error("start tunnel runtime failed", "err", err)
		return fmt.Errorf("start tunnel runtime: %w", err)
	}
	return nil
}

func (tunnelRuntimeAdapter) Stop() error {
	if err := tunnel.Stop(); err != nil {
		controlLogger.Error("stop tunnel runtime failed", "err", err)
		return fmt.Errorf("stop tunnel runtime: %w", err)
	}
	return nil
}

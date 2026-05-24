package controlserver

import (
	"celltunnel/daemon/internal/discovery"
	"celltunnel/daemon/internal/tunnel"
	"context"
	"testing"

	controlv1 "celltunnel/daemon/internal/controlv1"
)

func TestStatusRPC(t *testing.T) {
	service := NewService(
		&fakeTunnelRuntime{
			status: tunnel.RuntimeStatus{
				Running:     true,
				RouteState:  "installed",
				IPv4Address: "198.18.0.2",
				IPv6Address: "fd7a:ce11:7a11::2",
			},
		},
		&fakeRelayDiscovery{
			snapshot: discovery.Snapshot{
				Phase:             discovery.PhaseReady,
				SelectedServiceID: "relay-1",
				SelectedEndpoint: &discovery.Endpoint{
					Host:   "fd00::5",
					Port:   5354,
					Family: discovery.AddressFamilyIPv6,
				},
			},
		},
	)

	response, err := service.Status(context.Background(), &controlv1.StatusRequest{})
	if err != nil {
		t.Fatalf("status error: %v", err)
	}

	statusResult, ok := response.Result.(*controlv1.StatusResponse_Status)
	if !ok {
		t.Fatalf("status result type = %T", response.Result)
	}
	if !statusResult.Status.Running {
		t.Fatal("status did not report running tunnel")
	}
	if statusResult.Status.Route.GetState() != controlv1.RouteState_ROUTE_STATE_INSTALLED {
		t.Fatalf("route state = %v", statusResult.Status.Route.GetState())
	}
	if statusResult.Status.Peer.GetState() != controlv1.PeerState_PEER_STATE_WIREGUARD_CONFIGURED {
		t.Fatalf("peer state = %v", statusResult.Status.Peer.GetState())
	}
}

func TestCheckRPC(t *testing.T) {
	service := NewService(
		&fakeTunnelRuntime{
			checks: []tunnel.EnvironmentCheck{
				{Name: "utun", Value: "available"},
				{Name: "wireguard_runtime", Value: "available"},
			},
		},
		&fakeRelayDiscovery{},
	)

	response, err := service.Check(context.Background(), &controlv1.CheckRequest{})
	if err != nil {
		t.Fatalf("check error: %v", err)
	}

	reportResult, ok := response.Result.(*controlv1.CheckResponse_Report)
	if !ok {
		t.Fatalf("check result type = %T", response.Result)
	}
	if len(reportResult.Report.Checks) != 2 {
		t.Fatalf("check count = %d", len(reportResult.Report.Checks))
	}
}

func TestStartTunnelRPCUsesExplicitRelay(t *testing.T) {
	runtime := &fakeTunnelRuntime{
		status: tunnel.RuntimeStatus{
			RouteState:  "not-installed",
			IPv4Address: "198.18.0.2",
			IPv6Address: "fd7a:ce11:7a11::2",
		},
	}
	service := NewService(runtime, &fakeRelayDiscovery{})

	response, err := service.StartTunnel(context.Background(), &controlv1.StartTunnelRequest{
		Settings: &controlv1.TunnelStartSettings{
			WireGuardConfigPath: "/tmp/wg.conf",
			RelayEndpoint: &controlv1.RelayEndpoint{
				Host:          "fd00::8",
				Port:          5354,
				AddressFamily: controlv1.AddressFamily_ADDRESS_FAMILY_IPV6,
			},
		},
	})
	if err != nil {
		t.Fatalf("start error: %v", err)
	}

	statusResult, ok := response.Result.(*controlv1.StartTunnelResponse_Status)
	if !ok {
		t.Fatalf("start result type = %T", response.Result)
	}
	if runtime.startOptions.WireGuardConfigPath != "/tmp/wg.conf" {
		t.Fatalf("config path = %q", runtime.startOptions.WireGuardConfigPath)
	}
	if runtime.startOptions.LocalRelayEndpoint != "[fd00::8]:5354" {
		t.Fatalf("relay endpoint = %q", runtime.startOptions.LocalRelayEndpoint)
	}
	if statusResult.Status.ActiveRelayEndpoint.GetHost() != "fd00::8" {
		t.Fatalf("active relay host = %q", statusResult.Status.ActiveRelayEndpoint.GetHost())
	}
}

func TestStartTunnelRPCUsesSelectedRelay(t *testing.T) {
	runtime := &fakeTunnelRuntime{
		status: tunnel.RuntimeStatus{
			RouteState:  "not-installed",
			IPv4Address: "198.18.0.2",
			IPv6Address: "fd7a:ce11:7a11::2",
		},
	}
	service := NewService(runtime, &fakeRelayDiscovery{
		selectedEndpoint: &discovery.Endpoint{
			Host:   "fd00::9",
			Port:   5355,
			Family: discovery.AddressFamilyIPv6,
		},
	})

	response, err := service.StartTunnel(context.Background(), &controlv1.StartTunnelRequest{
		Settings: &controlv1.TunnelStartSettings{
			WireGuardConfigPath: "/tmp/wg.conf",
		},
	})
	if err != nil {
		t.Fatalf("start error: %v", err)
	}

	if _, ok := response.Result.(*controlv1.StartTunnelResponse_Status); !ok {
		t.Fatalf("start result type = %T", response.Result)
	}
	if runtime.startOptions.LocalRelayEndpoint != "[fd00::9]:5355" {
		t.Fatalf("selected relay endpoint = %q", runtime.startOptions.LocalRelayEndpoint)
	}
}

func TestStartTunnelRPCRejectsMissingSelectedRelay(t *testing.T) {
	service := NewService(&fakeTunnelRuntime{}, &fakeRelayDiscovery{})

	response, err := service.StartTunnel(context.Background(), &controlv1.StartTunnelRequest{
		Settings: &controlv1.TunnelStartSettings{
			WireGuardConfigPath: "/tmp/wg.conf",
		},
	})
	if err != nil {
		t.Fatalf("start error: %v", err)
	}

	errorResult, ok := response.Result.(*controlv1.StartTunnelResponse_Error)
	if !ok {
		t.Fatalf("start result type = %T", response.Result)
	}
	if errorResult.Error.GetCode() != controlv1.ControlErrorCode_CONTROL_ERROR_CODE_RELAY_SELECTION_REQUIRED {
		t.Fatalf("error code = %v", errorResult.Error.GetCode())
	}
}

func TestStopTunnelRPC(t *testing.T) {
	runtime := &fakeTunnelRuntime{
		status: tunnel.RuntimeStatus{
			Running:     true,
			RouteState:  "installed",
			IPv4Address: "198.18.0.2",
			IPv6Address: "fd7a:ce11:7a11::2",
		},
	}
	service := NewService(runtime, &fakeRelayDiscovery{})
	service.activeRelayEndpoint = &discovery.Endpoint{
		Host:   "fd00::5",
		Port:   5354,
		Family: discovery.AddressFamilyIPv6,
	}

	response, err := service.StopTunnel(context.Background(), &controlv1.StopTunnelRequest{})
	if err != nil {
		t.Fatalf("stop error: %v", err)
	}

	if _, ok := response.Result.(*controlv1.StopTunnelResponse_Status); !ok {
		t.Fatalf("stop result type = %T", response.Result)
	}
	if runtime.stopCount != 1 {
		t.Fatalf("stop count = %d", runtime.stopCount)
	}
}

func TestStartRelayDiscoveryRPC(t *testing.T) {
	discoveryManager := &fakeRelayDiscovery{
		snapshot: discovery.Snapshot{
			Phase: discovery.PhaseBrowsing,
		},
	}
	service := NewService(&fakeTunnelRuntime{}, discoveryManager)

	response, err := service.StartRelayDiscovery(context.Background(), &controlv1.StartRelayDiscoveryRequest{})
	if err != nil {
		t.Fatalf("start discovery error: %v", err)
	}

	if _, ok := response.Result.(*controlv1.StartRelayDiscoveryResponse_Discovery); !ok {
		t.Fatalf("start discovery result type = %T", response.Result)
	}
	if discoveryManager.startCount != 1 {
		t.Fatalf("start discovery count = %d", discoveryManager.startCount)
	}
}

func TestStopRelayDiscoveryRPC(t *testing.T) {
	discoveryManager := &fakeRelayDiscovery{
		snapshot: discovery.Snapshot{
			Phase: discovery.PhaseReady,
		},
	}
	service := NewService(&fakeTunnelRuntime{}, discoveryManager)

	response, err := service.StopRelayDiscovery(context.Background(), &controlv1.StopRelayDiscoveryRequest{})
	if err != nil {
		t.Fatalf("stop discovery error: %v", err)
	}

	if _, ok := response.Result.(*controlv1.StopRelayDiscoveryResponse_Discovery); !ok {
		t.Fatalf("stop discovery result type = %T", response.Result)
	}
	if discoveryManager.stopCount != 1 {
		t.Fatalf("stop discovery count = %d", discoveryManager.stopCount)
	}
}

func TestListRelayServicesRPC(t *testing.T) {
	service := NewService(&fakeTunnelRuntime{}, &fakeRelayDiscovery{
		snapshot: discovery.Snapshot{
			Phase: discovery.PhaseReady,
			Services: []discovery.Service{
				{
					Identity: discovery.Identity{
						ServiceID:   "relay-1",
						ServiceName: "CellTunnelPhone",
						ServiceType: "_cellrelay._tcp",
						Domain:      "local.",
					},
				},
			},
		},
	})

	response, err := service.ListRelayServices(context.Background(), &controlv1.ListRelayServicesRequest{})
	if err != nil {
		t.Fatalf("list services error: %v", err)
	}

	discoveryResult, ok := response.Result.(*controlv1.ListRelayServicesResponse_Discovery)
	if !ok {
		t.Fatalf("list services result type = %T", response.Result)
	}
	if len(discoveryResult.Discovery.Services) != 1 {
		t.Fatalf("service count = %d", len(discoveryResult.Discovery.Services))
	}
}

func TestSelectRelayServiceRPC(t *testing.T) {
	discoveryManager := &fakeRelayDiscovery{
		snapshot: discovery.Snapshot{
			Phase: discovery.PhaseReady,
			Services: []discovery.Service{
				{
					Identity: discovery.Identity{
						ServiceID:   "relay-1",
						ServiceName: "CellTunnelPhone",
						ServiceType: "_cellrelay._tcp",
						Domain:      "local.",
					},
					PreferredEndpoint: &discovery.Endpoint{
						Host:   "fd00::12",
						Port:   5354,
						Family: discovery.AddressFamilyIPv6,
					},
				},
			},
		},
	}
	service := NewService(&fakeTunnelRuntime{}, discoveryManager)

	response, err := service.SelectRelayService(context.Background(), &controlv1.SelectRelayServiceRequest{
		ServiceId: "relay-1",
	})
	if err != nil {
		t.Fatalf("select relay error: %v", err)
	}

	if _, ok := response.Result.(*controlv1.SelectRelayServiceResponse_Discovery); !ok {
		t.Fatalf("select relay result type = %T", response.Result)
	}
	if discoveryManager.selectedServiceID != "relay-1" {
		t.Fatalf("selected service = %q", discoveryManager.selectedServiceID)
	}
}

type fakeTunnelRuntime struct {
	status       tunnel.RuntimeStatus
	checks       []tunnel.EnvironmentCheck
	startOptions tunnel.StartOptions
	startError   error
	stopCount    int
	stopError    error
}

func (runtime *fakeTunnelRuntime) Status() tunnel.RuntimeStatus {
	return runtime.status
}

func (runtime *fakeTunnelRuntime) CheckEnvironment() []tunnel.EnvironmentCheck {
	return runtime.checks
}

func (runtime *fakeTunnelRuntime) Start(options tunnel.StartOptions) error {
	runtime.startOptions = options
	if runtime.startError != nil {
		return runtime.startError
	}
	runtime.status.Running = true
	runtime.status.RouteState = "installed"
	return nil
}

func (runtime *fakeTunnelRuntime) Stop() error {
	runtime.stopCount++
	runtime.status.Running = false
	runtime.status.RouteState = "not-installed"
	return runtime.stopError
}

type fakeRelayDiscovery struct {
	snapshot          discovery.Snapshot
	selectedEndpoint  *discovery.Endpoint
	selectedServiceID string
	startCount        int
	stopCount         int
	startError        error
	stopError         error
	selectError       error
}

func (relay *fakeRelayDiscovery) Start() error {
	relay.startCount++
	return relay.startError
}

func (relay *fakeRelayDiscovery) Stop() error {
	relay.stopCount++
	return relay.stopError
}

func (relay *fakeRelayDiscovery) Snapshot() discovery.Snapshot {
	return relay.snapshot
}

func (relay *fakeRelayDiscovery) SelectService(serviceID string) error {
	if relay.selectError != nil {
		return relay.selectError
	}
	relay.selectedServiceID = serviceID
	for index, service := range relay.snapshot.Services {
		selected := service.Identity.ServiceID == serviceID
		relay.snapshot.Services[index].IsSelected = selected
		if selected {
			relay.snapshot.SelectedServiceID = serviceID
			relay.snapshot.SelectedEndpoint = service.PreferredEndpoint
			relay.selectedEndpoint = service.PreferredEndpoint
		}
	}
	return nil
}

func (relay *fakeRelayDiscovery) SelectedEndpoint() (discovery.Endpoint, bool) {
	if relay.selectedEndpoint == nil {
		return discovery.Endpoint{}, false
	}
	return *relay.selectedEndpoint, true
}

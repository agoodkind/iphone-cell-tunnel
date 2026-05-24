package controlserver

import (
	"celltunnel/daemon/internal/discovery"
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	controlv1 "celltunnel/daemon/internal/controlv1"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func TestBlockingGRPCConnectAndStatusRPC(t *testing.T) {
	socketPath, cleanup := startTestControlServer(t, NewService(&fakeTunnelRuntime{}, &fakeRelayDiscovery{}))
	defer cleanup()

	client, connection := newTestGRPCClient(t, socketPath, true)
	defer func() {
		_ = connection.Close()
	}()

	rpcContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	response, err := client.Status(rpcContext, &controlv1.StatusRequest{})
	if err != nil {
		t.Fatalf("status rpc failed: %v", err)
	}

	status := response.GetStatus()
	if status == nil {
		t.Fatal("status response was nil")
	}
	if status.GetRunning() {
		t.Fatal("expected test runtime to report stopped")
	}
}

func TestNonBlockingGRPCConnectAndStatusRPC(t *testing.T) {
	socketPath, cleanup := startTestControlServer(t, NewService(&fakeTunnelRuntime{}, &fakeRelayDiscovery{}))
	defer cleanup()

	client, connection := newTestGRPCClient(t, socketPath, false)
	defer func() {
		_ = connection.Close()
	}()

	rpcContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	response, err := client.Status(rpcContext, &controlv1.StatusRequest{})
	if err != nil {
		t.Fatalf("status rpc failed: %v", err)
	}

	status := response.GetStatus()
	if status == nil {
		t.Fatal("status response was nil")
	}
	if status.GetRunning() {
		t.Fatal("expected test runtime to report stopped")
	}
}

func TestDiscoveryRPCsOverUnixSocket(t *testing.T) {
	relayDiscovery := &fakeRelayDiscovery{
		snapshot: discoverySnapshotFixture(),
	}
	socketPath, cleanup := startTestControlServer(t, NewService(&fakeTunnelRuntime{}, relayDiscovery))
	defer cleanup()

	client, connection := newTestGRPCClient(t, socketPath, true)
	defer func() {
		_ = connection.Close()
	}()

	rpcContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	startResponse, err := client.StartRelayDiscovery(rpcContext, &controlv1.StartRelayDiscoveryRequest{})
	if err != nil {
		t.Fatalf("start discovery rpc failed: %v", err)
	}
	if startResponse.GetDiscovery() == nil {
		t.Fatal("start discovery response was nil")
	}

	listResponse, err := client.ListRelayServices(rpcContext, &controlv1.ListRelayServicesRequest{})
	if err != nil {
		t.Fatalf("list relay services rpc failed: %v", err)
	}
	if got := len(listResponse.GetDiscovery().GetServices()); got != 1 {
		t.Fatalf("service count = %d", got)
	}
	if relayDiscovery.startCount != 1 {
		t.Fatalf("start discovery count = %d", relayDiscovery.startCount)
	}
}

func startTestControlServer(t *testing.T, service *Service) (string, func()) {
	t.Helper()

	directory, err := os.MkdirTemp("/tmp", "celltunnel-grpc-control-")
	if err != nil {
		t.Fatalf("create temp directory: %v", err)
	}

	socketPath := filepath.Join(directory, "control.sock")
	serverContext, cancel := context.WithCancel(context.Background())
	serverErrors := make(chan error, 1)
	go func() {
		serverErrors <- Serve(serverContext, socketPath, service)
	}()

	waitForSocket(t, socketPath)

	return socketPath, func() {
		cancel()
		if err := <-serverErrors; err != nil {
			t.Fatalf("server error: %v", err)
		}
		_ = os.RemoveAll(directory)
	}
}

func newTestGRPCClient(
	t *testing.T,
	socketPath string,
	useBlockingConnect bool,
) (controlv1.TunnelControlServiceClient, *grpc.ClientConn) {
	t.Helper()

	dialContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	options := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
			return net.Dial("unix", socketPath)
		}),
	}
	if useBlockingConnect {
		options = append(options, grpc.WithBlock())
	}

	connection, err := grpc.DialContext(dialContext, "unix://"+socketPath, options...)
	if err != nil {
		t.Fatalf("dial control socket: %v", err)
	}

	return controlv1.NewTunnelControlServiceClient(connection), connection
}

func discoverySnapshotFixture() discovery.Snapshot {
	return discovery.Snapshot{
		Phase: discovery.PhaseReady,
		Services: []discovery.Service{
			{
				Identity: discovery.Identity{
					ServiceID:      "relay-1",
					ServiceName:    "CellTunnelPhone",
					ServiceType:    "_cellrelay._tcp",
					Domain:         "local.",
					InterfaceIndex: 1,
				},
				HostName: "iphone.local",
				Endpoints: []discovery.Endpoint{
					{
						Host:   "fd00::12",
						Port:   57373,
						Family: discovery.AddressFamilyIPv6,
					},
				},
				PreferredEndpoint: &discovery.Endpoint{
					Host:   "fd00::12",
					Port:   57373,
					Family: discovery.AddressFamilyIPv6,
				},
				IsSelected: true,
			},
		},
		SelectedServiceID: "relay-1",
		SelectedEndpoint: &discovery.Endpoint{
			Host:   "fd00::12",
			Port:   57373,
			Family: discovery.AddressFamilyIPv6,
		},
	}
}

package controlserver

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestJSONControlRequestsAreRejected(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "celltunnel-grpc-control-")
	if err != nil {
		t.Fatalf("create temp directory: %v", err)
	}
	defer func() {
		_ = os.RemoveAll(directory)
	}()

	socketPath := filepath.Join(directory, "control.sock")
	service := NewService(&fakeTunnelRuntime{}, &fakeRelayDiscovery{})
	serverContext, cancel := context.WithCancel(context.Background())
	defer cancel()

	serverErrors := make(chan error, 1)
	go func() {
		serverErrors <- Serve(serverContext, socketPath, service)
	}()

	waitForSocket(t, socketPath)

	connection, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial socket: %v", err)
	}
	defer func() {
		_ = connection.Close()
	}()

	if err := connection.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	if _, err := connection.Write([]byte("{\"method\":\"status\"}\n")); err != nil {
		t.Fatalf("write json probe: %v", err)
	}

	buffer := make([]byte, 1024)
	count, readErr := connection.Read(buffer)
	if readErr == nil && count > 0 && json.Valid(buffer[:count]) {
		t.Fatalf("received legacy JSON response: %q", string(buffer[:count]))
	}

	_ = connection.Close()
	cancel()
	if err := <-serverErrors; err != nil {
		t.Fatalf("server error: %v", err)
	}
}

func TestControlSocketAllowsUserClients(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "celltunnel-grpc-control-")
	if err != nil {
		t.Fatalf("create temp directory: %v", err)
	}
	defer func() {
		_ = os.RemoveAll(directory)
	}()

	socketPath := filepath.Join(directory, "control.sock")
	service := NewService(&fakeTunnelRuntime{}, &fakeRelayDiscovery{})
	serverContext, cancel := context.WithCancel(context.Background())
	defer cancel()

	serverErrors := make(chan error, 1)
	go func() {
		serverErrors <- Serve(serverContext, socketPath, service)
	}()

	waitForSocket(t, socketPath)
	fileInfo, err := os.Stat(socketPath)
	if err != nil {
		t.Fatalf("stat socket: %v", err)
	}
	if got := fileInfo.Mode().Perm(); got != 0o666 {
		t.Fatalf("socket mode = %v, want 0666", got)
	}

	cancel()
	if err := <-serverErrors; err != nil {
		t.Fatalf("server error: %v", err)
	}
}

func waitForSocket(t *testing.T, socketPath string) {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(socketPath); err == nil {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("socket did not appear at %s", socketPath)
}

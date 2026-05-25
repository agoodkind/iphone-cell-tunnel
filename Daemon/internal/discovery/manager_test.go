package discovery

import (
	"testing"
	"time"
)

type callbackStopDriver struct {
	sink eventSink
}

func (driver *callbackStopDriver) Start() error {
	return nil
}

func (driver *callbackStopDriver) Stop() error {
	driver.sink.stopped()
	return nil
}

func TestManagerStopAllowsDriverStoppedCallback(t *testing.T) {
	manager := NewManager()
	manager.factory = func(sink eventSink) (driver, error) {
		return &callbackStopDriver{sink: sink}, nil
	}
	if err := manager.Start(); err != nil {
		t.Fatalf("start manager: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- manager.Stop()
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("stop manager: %v", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("manager stop deadlocked")
	}
}

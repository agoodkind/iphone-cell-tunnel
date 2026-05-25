package discovery

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"
)

type driver interface {
	Start() error
	Stop() error
}

type driverFactory func(sink eventSink) (driver, error)

type eventSink interface {
	address(AddressEvent)
	browse(BrowseEvent)
	fail(error)
	resolve(ResolveEvent)
	stopped()
}

var discoveryLogger = slog.Default().With("component", "discovery")

// Manager owns DNS-SD discovery lifecycle and selected relay state.
type Manager struct {
	mutex   sync.Mutex
	store   stateStore
	driver  driver
	factory driverFactory
}

// NewManager creates a daemon discovery manager with the platform DNS-SD driver.
func NewManager() *Manager {
	return &Manager{
		store:   newStateStore(),
		factory: newDriver,
	}
}

// Start begins DNS-SD discovery if it is not already active.
func (manager *Manager) Start() error {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	if manager.driver != nil {
		return nil
	}

	driver, err := manager.factory(manager)
	if err != nil {
		manager.store.fail(err.Error())
		discoveryLogger.Error("create discovery driver failed", "err", err)
		return fmt.Errorf("create discovery driver: %w", err)
	}
	manager.store.beginBrowsing()
	if err := driver.Start(); err != nil {
		manager.store.fail(err.Error())
		discoveryLogger.Error("start discovery driver failed", "err", err)
		return fmt.Errorf("start discovery driver: %w", err)
	}

	manager.driver = driver
	return nil
}

// Stop ends DNS-SD discovery and preserves the last known selected relay.
func (manager *Manager) Stop() error {
	manager.mutex.Lock()

	if manager.driver == nil {
		manager.store.stopBrowsing()
		manager.mutex.Unlock()
		return nil
	}

	activeDriver := manager.driver
	manager.driver = nil
	manager.store.stopBrowsing()
	manager.mutex.Unlock()

	if err := activeDriver.Stop(); err != nil {
		discoveryLogger.Error("stop discovery driver failed", "err", err)
		return fmt.Errorf("stop discovery driver: %w", err)
	}
	return nil
}

// Snapshot returns the current daemon-owned discovery state.
func (manager *Manager) Snapshot() Snapshot {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	return manager.store.snapshot()
}

// SelectService updates the daemon-owned relay selection.
func (manager *Manager) SelectService(serviceID string) error {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	if !manager.store.selectService(serviceID) {
		return errors.New("relay service not found")
	}
	return nil
}

// SelectedEndpoint returns the current daemon-selected relay endpoint, if one exists.
func (manager *Manager) SelectedEndpoint() (Endpoint, bool) {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	if manager.store.selectedEndpoint == nil {
		return Endpoint{}, false
	}
	return *manager.store.selectedEndpoint, true
}

func (manager *Manager) browse(event BrowseEvent) {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	manager.store.applyBrowse(event)
}

func (manager *Manager) resolve(event ResolveEvent) {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	manager.store.applyResolve(event)
}

func (manager *Manager) address(event AddressEvent) {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	manager.store.applyAddress(event)
}

func (manager *Manager) fail(err error) {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	manager.store.fail(err.Error())
}

func (manager *Manager) stopped() {
	manager.mutex.Lock()
	defer manager.mutex.Unlock()

	manager.store.stopBrowsing()
}

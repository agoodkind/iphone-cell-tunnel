package discovery

import (
	"slices"
	"strconv"
)

type serviceState struct {
	identity          Identity
	hostName          string
	port              uint32
	endpoints         []Endpoint
	preferredEndpoint *Endpoint
}

type stateStore struct {
	phase             Phase
	services          map[string]serviceState
	selectedServiceID string
	selectedEndpoint  *Endpoint
	selectedAuto      bool
	lastError         string
}

var preferredReadyService = selectPreferredReadyService

func newStateStore() stateStore {
	return stateStore{
		phase:    PhaseStopped,
		services: make(map[string]serviceState),
	}
}

func serviceID(name string, serviceType string, domain string, interfaceIndex uint32) string {
	return name + "." + serviceType + "." + domain + "." + strconv.FormatUint(uint64(interfaceIndex), 10)
}

func (store *stateStore) beginBrowsing() {
	store.phase = PhaseBrowsing
	store.lastError = ""
}

func (store *stateStore) stopBrowsing() {
	store.phase = PhaseStopped
}

func (store *stateStore) fail(message string) {
	store.phase = PhaseFailed
	store.lastError = message
	store.clearSelection()
}

func (store *stateStore) applyBrowse(event BrowseEvent) string {
	id := serviceID(event.ServiceName, event.ServiceType, event.Domain, event.InterfaceIndex)
	if !event.Add {
		delete(store.services, id)
		if store.selectedServiceID == id {
			store.selectedServiceID = ""
			store.selectedEndpoint = nil
			store.selectedAuto = false
		}
		store.updatePhaseForServices()
		return id
	}

	if _, exists := store.services[id]; !exists {
		store.services[id] = serviceState{
			identity: Identity{
				ServiceID:      id,
				ServiceName:    event.ServiceName,
				ServiceType:    event.ServiceType,
				Domain:         event.Domain,
				InterfaceIndex: event.InterfaceIndex,
			},
		}
	}
	store.updatePhaseForServices()
	return id
}

func (store *stateStore) applyResolve(event ResolveEvent) {
	service, exists := store.services[event.ServiceID]
	if !exists {
		return
	}
	service.hostName = event.HostName
	service.port = event.Port
	service.endpoints = nil
	service.preferredEndpoint = nil
	store.services[event.ServiceID] = service
	store.updateSelection()
}

func (store *stateStore) applyAddress(event AddressEvent) {
	service, exists := store.services[event.ServiceID]
	if !exists {
		return
	}
	if event.Host == "" || service.port == 0 {
		return
	}

	endpoint := Endpoint{
		Host:   scopedHost(event.Host, event.Family, service.identity.InterfaceIndex),
		Port:   service.port,
		Family: event.Family,
	}
	if !slices.Contains(service.endpoints, endpoint) {
		service.endpoints = append(service.endpoints, endpoint)
	}
	service.preferredEndpoint = preferredEndpoint(service.endpoints)
	store.services[event.ServiceID] = service
	store.updateSelection()
	store.updatePhaseForServices()
}

func (store *stateStore) selectService(serviceID string) bool {
	service, exists := store.services[serviceID]
	if !exists || service.preferredEndpoint == nil {
		return false
	}
	store.selectedServiceID = serviceID
	selected := *service.preferredEndpoint
	store.selectedEndpoint = &selected
	store.selectedAuto = false
	return true
}

func (store *stateStore) snapshot() Snapshot {
	services := make([]Service, 0, len(store.services))
	for _, service := range store.services {
		services = append(services, Service{
			Identity:          service.identity,
			HostName:          service.hostName,
			Endpoints:         slices.Clone(service.endpoints),
			PreferredEndpoint: cloneEndpoint(service.preferredEndpoint),
			IsSelected:        service.identity.ServiceID == store.selectedServiceID,
		})
	}
	sortServices(services)
	return Snapshot{
		Phase:             store.phase,
		Services:          services,
		SelectedServiceID: store.selectedServiceID,
		SelectedEndpoint:  cloneEndpoint(store.selectedEndpoint),
		LastError:         store.lastError,
	}
}

func (store *stateStore) updatePhaseForServices() {
	if store.phase == PhaseFailed || store.phase == PhaseStopped {
		return
	}
	for _, service := range store.services {
		if service.preferredEndpoint != nil {
			store.phase = PhaseReady
			return
		}
	}
	store.phase = PhaseBrowsing
}

func (store *stateStore) updateSelection() {
	if store.syncExistingSelection() {
		return
	}

	readyServices := make([]serviceState, 0, len(store.services))
	for _, service := range store.services {
		if service.preferredEndpoint != nil {
			readyServices = append(readyServices, service)
		}
	}
	if len(readyServices) == 1 {
		service := readyServices[0]
		store.selectedServiceID = service.identity.ServiceID
		selected := *service.preferredEndpoint
		store.selectedEndpoint = &selected
		store.selectedAuto = true
		return
	}
	if preferredService := preferredReadyService(readyServices); preferredService != nil {
		store.selectedServiceID = preferredService.identity.ServiceID
		selected := *preferredService.preferredEndpoint
		store.selectedEndpoint = &selected
		store.selectedAuto = true
	}
}

func (store *stateStore) syncExistingSelection() bool {
	if store.selectedServiceID == "" {
		return false
	}

	service, exists := store.services[store.selectedServiceID]
	if !exists || service.preferredEndpoint == nil {
		store.clearSelection()
		return false
	}

	if store.selectedAuto && store.readyServiceCount() != 1 {
		store.clearSelection()
		return false
	}

	selected := *service.preferredEndpoint
	store.selectedEndpoint = &selected
	return true
}

func (store *stateStore) readyServiceCount() int {
	readyServiceCount := 0
	for _, candidate := range store.services {
		if candidate.preferredEndpoint != nil {
			readyServiceCount++
		}
	}
	return readyServiceCount
}

func (store *stateStore) clearSelection() {
	store.selectedServiceID = ""
	store.selectedEndpoint = nil
	store.selectedAuto = false
}

func cloneEndpoint(endpoint *Endpoint) *Endpoint {
	if endpoint == nil {
		return nil
	}
	selected := *endpoint
	return &selected
}

func selectPreferredReadyService(services []serviceState) *serviceState {
	usbLikeServices := make([]serviceState, 0, len(services))
	for _, service := range services {
		if isUSBLocalInterface(service.identity.InterfaceIndex) {
			usbLikeServices = append(usbLikeServices, service)
		}
	}
	if len(usbLikeServices) != 1 {
		return nil
	}
	selected := usbLikeServices[0]
	return &selected
}

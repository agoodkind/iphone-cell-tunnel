//go:build darwin

package discovery

/*
#cgo LDFLAGS: -framework CoreServices
#include <arpa/inet.h>
#include <dns_sd.h>
#include <stdint.h>
#include <stdlib.h>

extern void GoBrowseCallback(uintptr_t handle, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, const char *serviceName, const char *regtype, const char *replyDomain);
extern void GoResolveCallback(uintptr_t handle, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, const char *hosttarget, uint16_t port);
extern void GoAddrInfoCallback(uintptr_t handle, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, int family, const void *address);

static void browseCallback(
    DNSServiceRef serviceRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    DNSServiceErrorType errorCode,
    const char *serviceName,
    const char *regtype,
    const char *replyDomain,
    void *context
) {
    (void)serviceRef;
    GoBrowseCallback((uintptr_t)context, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain);
}

static void resolveCallback(
    DNSServiceRef serviceRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    DNSServiceErrorType errorCode,
    const char *fullname,
    const char *hosttarget,
    uint16_t port,
    uint16_t txtLen,
    const unsigned char *txtRecord,
    void *context
) {
    (void)serviceRef;
    (void)fullname;
    (void)txtLen;
    (void)txtRecord;
    GoResolveCallback((uintptr_t)context, flags, interfaceIndex, errorCode, hosttarget, ntohs(port));
}

static void addrInfoCallback(
    DNSServiceRef serviceRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    DNSServiceErrorType errorCode,
    const char *hostname,
    const struct sockaddr *address,
    uint32_t ttl,
    void *context
) {
    (void)serviceRef;
    (void)hostname;
    (void)ttl;
    GoAddrInfoCallback((uintptr_t)context, flags, interfaceIndex, errorCode, address != NULL ? address->sa_family : 0, address);
}

static DNSServiceRef startBrowse(
    uintptr_t handle,
    const char *serviceType,
    const char *domain,
    DNSServiceErrorType *errorCode
) {
    DNSServiceRef serviceRef = NULL;
    *errorCode = DNSServiceBrowse(
        &serviceRef,
        kDNSServiceFlagsIncludeP2P,
        0,
        serviceType,
        domain,
        browseCallback,
        (void *)handle
    );
    return serviceRef;
}

static DNSServiceRef startResolve(
    uintptr_t handle,
    uint32_t interfaceIndex,
    const char *serviceName,
    const char *serviceType,
    const char *domain,
    DNSServiceErrorType *errorCode
) {
    DNSServiceRef serviceRef = NULL;
    *errorCode = DNSServiceResolve(
        &serviceRef,
        kDNSServiceFlagsIncludeP2P,
        interfaceIndex,
        serviceName,
        serviceType,
        domain,
        resolveCallback,
        (void *)handle
    );
    return serviceRef;
}

static DNSServiceRef startAddrInfo(
    uintptr_t handle,
    uint32_t interfaceIndex,
    const char *hostName,
    DNSServiceErrorType *errorCode
) {
    DNSServiceRef serviceRef = NULL;
    *errorCode = DNSServiceGetAddrInfo(
        &serviceRef,
        kDNSServiceFlagsIncludeP2P,
        interfaceIndex,
        kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6,
        hostName,
        addrInfoCallback,
        (void *)handle
    );
    return serviceRef;
}
*/
import "C"

import (
	"errors"
	"fmt"
	"log/slog"
	"runtime/cgo"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	defaultBrowseDomain  = "local."
	defaultBrowseService = "_cellrelay._tcp"
)

type dnsSDDriver struct {
	sink        eventSink
	mutex       sync.Mutex
	events      chan dnsSDEvent
	stopChannel chan struct{}
	stopOnce    sync.Once
	browse      *serviceLoop
	resolves    map[string]*serviceLoop
	address     map[string]*serviceLoop
	eventDone   chan struct{}
}

type browseCallbackContext struct {
	driver *dnsSDDriver
}

type resolveCallbackContext struct {
	driver    *dnsSDDriver
	serviceID string
}

type addrInfoCallbackContext struct {
	driver    *dnsSDDriver
	serviceID string
}

type serviceLoop struct {
	ref         C.DNSServiceRef
	handle      cgo.Handle
	name        string
	stopChannel <-chan struct{}
	done        chan struct{}
}

type dnsSDEventKind string

const (
	dnsSDEventBrowse   dnsSDEventKind = "browse"
	dnsSDEventResolve  dnsSDEventKind = "resolve"
	dnsSDEventAddrInfo dnsSDEventKind = "addrinfo"
)

type dnsSDEvent struct {
	kind     dnsSDEventKind
	browse   dnsSDBrowseEvent
	resolve  dnsSDResolveEvent
	addrInfo dnsSDAddrInfoEvent
}

type dnsSDBrowseEvent struct {
	flags          uint32
	interfaceIndex uint32
	errorCode      int32
	serviceName    string
	serviceType    string
	domain         string
}

type dnsSDResolveEvent struct {
	serviceID      string
	interfaceIndex uint32
	errorCode      int32
	hostName       string
	port           uint16
}

type dnsSDAddrInfoEvent struct {
	serviceID string
	flags     uint32
	errorCode int32
	family    int
	address   string
}

func newDriver(sink eventSink) (driver, error) {
	return &dnsSDDriver{
		sink:        sink,
		events:      make(chan dnsSDEvent, 64),
		stopChannel: make(chan struct{}),
		resolves:    make(map[string]*serviceLoop),
		address:     make(map[string]*serviceLoop),
	}, nil
}

func (driver *dnsSDDriver) Start() error {
	driver.mutex.Lock()
	defer driver.mutex.Unlock()

	if driver.browse != nil {
		return nil
	}

	callbackHandle := cgo.NewHandle(browseCallbackContext{driver: driver})
	serviceType := C.CString(defaultBrowseService)
	domain := C.CString(defaultBrowseDomain)
	defer C.free(unsafe.Pointer(serviceType))
	defer C.free(unsafe.Pointer(domain))

	callbackHandleValue := C.uintptr_t(callbackHandle)
	var result C.DNSServiceErrorType
	serviceRef := C.startBrowse(callbackHandleValue, serviceType, domain, &result)
	if result != C.kDNSServiceErr_NoError {
		callbackHandle.Delete()
		return dnsError("browse", int32(result))
	}

	driver.startEventLoop()
	driver.browse = newServiceLoop(serviceRef, callbackHandle, driver.stopChannel, "browse")
	driver.browse.start(func(err error) {
		driver.sink.fail(fmt.Errorf("browse loop failed: %w", err))
	})
	return nil
}

func (driver *dnsSDDriver) Stop() error {
	driver.stopOnce.Do(func() {
		close(driver.stopChannel)
	})

	driver.mutex.Lock()

	var stopError error
	if driver.browse != nil {
		stopError = errors.Join(stopError, driver.browse.stop())
		driver.browse = nil
	}
	for serviceIDValue, loop := range driver.resolves {
		stopError = errors.Join(stopError, loop.stop())
		delete(driver.resolves, serviceIDValue)
	}
	for serviceIDValue, loop := range driver.address {
		stopError = errors.Join(stopError, loop.stop())
		delete(driver.address, serviceIDValue)
	}
	driver.sink.stopped()
	eventDone := driver.eventDone
	driver.eventDone = nil
	driver.mutex.Unlock()

	if eventDone != nil {
		<-eventDone
	}
	return stopError
}

func (driver *dnsSDDriver) startEventLoop() {
	if driver.eventDone != nil {
		return
	}

	driver.eventDone = make(chan struct{})
	logger := slog.Default().With("component", "discovery", "loop", "events")
	go func() {
		defer close(driver.eventDone)
		defer func() {
			if recovered := recover(); recovered != nil {
				panicError := fmt.Errorf("dns-sd event loop panic: %v", recovered)
				logger.Error("dns-sd event loop panicked", "err", panicError)
			}
		}()

		for {
			select {
			case <-driver.stopChannel:
				return
			case event := <-driver.events:
				driver.dispatch(event)
			}
		}
	}()
}

func (driver *dnsSDDriver) dispatch(event dnsSDEvent) {
	select {
	case <-driver.stopChannel:
		return
	default:
	}

	switch event.kind {
	case dnsSDEventBrowse:
		driver.handleBrowse(event.browse)
	case dnsSDEventResolve:
		driver.handleResolve(event.resolve)
	case dnsSDEventAddrInfo:
		driver.handleAddrInfo(event.addrInfo)
	default:
		driver.sink.fail(fmt.Errorf("unknown dns-sd event kind %q", event.kind))
	}
}

func (driver *dnsSDDriver) handleBrowse(callbackEvent dnsSDBrowseEvent) {
	if callbackEvent.errorCode != int32(C.kDNSServiceErr_NoError) {
		driver.sink.fail(dnsError("browse callback", callbackEvent.errorCode))
		return
	}

	event := BrowseEvent{
		Add:            (callbackEvent.flags & uint32(C.kDNSServiceFlagsAdd)) != 0,
		ServiceName:    callbackEvent.serviceName,
		ServiceType:    callbackEvent.serviceType,
		Domain:         callbackEvent.domain,
		InterfaceIndex: callbackEvent.interfaceIndex,
	}
	serviceIDValue := serviceID(event.ServiceName, event.ServiceType, event.Domain, event.InterfaceIndex)
	if !event.Add {
		if err := driver.stopServiceLoops(serviceIDValue); err != nil {
			driver.sink.fail(fmt.Errorf("stop discovery service loops: %w", err))
		}
		driver.sink.browse(event)
		return
	}

	driver.sink.browse(event)
	if err := driver.startResolve(
		serviceIDValue,
		event.ServiceName,
		event.ServiceType,
		event.Domain,
		event.InterfaceIndex,
	); err != nil {
		driver.sink.fail(fmt.Errorf("start resolve loop: %w", err))
	}
}

func (driver *dnsSDDriver) handleResolve(callbackEvent dnsSDResolveEvent) {
	if callbackEvent.errorCode != int32(C.kDNSServiceErr_NoError) {
		driver.sink.fail(dnsError("resolve callback", callbackEvent.errorCode))
		return
	}

	trimmedHostName := strings.TrimSuffix(callbackEvent.hostName, ".")
	driver.sink.resolve(ResolveEvent{
		ServiceID: callbackEvent.serviceID,
		HostName:  trimmedHostName,
		Port:      uint32(callbackEvent.port),
	})
	if err := driver.startAddrInfo(callbackEvent.serviceID, trimmedHostName, callbackEvent.interfaceIndex); err != nil {
		driver.sink.fail(fmt.Errorf("start addrinfo loop: %w", err))
	}
}

func (driver *dnsSDDriver) handleAddrInfo(callbackEvent dnsSDAddrInfoEvent) {
	if callbackEvent.errorCode != int32(C.kDNSServiceErr_NoError) {
		driver.sink.fail(dnsError("addrinfo callback", callbackEvent.errorCode))
		return
	}
	if (callbackEvent.flags&uint32(C.kDNSServiceFlagsAdd)) == 0 || callbackEvent.address == "" {
		return
	}

	driver.sink.address(AddressEvent{
		ServiceID: callbackEvent.serviceID,
		Host:      callbackEvent.address,
		Family:    familyFromInt(callbackEvent.family),
	})
}

func (driver *dnsSDDriver) startResolve(
	serviceIDValue string,
	serviceName string,
	serviceType string,
	domain string,
	interfaceIndex uint32,
) error {
	driver.mutex.Lock()
	defer driver.mutex.Unlock()

	if loop, exists := driver.resolves[serviceIDValue]; exists {
		if err := loop.stop(); err != nil {
			discoveryLogger.Error("stop existing resolve loop failed", "err", err)
			return fmt.Errorf("stop existing resolve loop: %w", err)
		}
		delete(driver.resolves, serviceIDValue)
	}

	callbackHandle := cgo.NewHandle(resolveCallbackContext{
		driver:    driver,
		serviceID: serviceIDValue,
	})
	cServiceName := C.CString(serviceName)
	cServiceType := C.CString(serviceType)
	cDomain := C.CString(domain)
	defer C.free(unsafe.Pointer(cServiceName))
	defer C.free(unsafe.Pointer(cServiceType))
	defer C.free(unsafe.Pointer(cDomain))

	callbackHandleValue := C.uintptr_t(callbackHandle)
	var result C.DNSServiceErrorType
	serviceRef := C.startResolve(
		callbackHandleValue,
		C.uint32_t(interfaceIndex),
		cServiceName,
		cServiceType,
		cDomain,
		&result,
	)
	if result != C.kDNSServiceErr_NoError {
		callbackHandle.Delete()
		return dnsError("resolve", int32(result))
	}

	loop := newServiceLoop(serviceRef, callbackHandle, driver.stopChannel, "resolve")
	driver.resolves[serviceIDValue] = loop
	loop.start(func(err error) {
		driver.sink.fail(fmt.Errorf("resolve loop failed: %w", err))
	})
	return nil
}

func (driver *dnsSDDriver) startAddrInfo(serviceIDValue string, hostName string, interfaceIndex uint32) error {
	driver.mutex.Lock()
	defer driver.mutex.Unlock()

	if loop, exists := driver.address[serviceIDValue]; exists {
		if err := loop.stop(); err != nil {
			discoveryLogger.Error("stop existing addrinfo loop failed", "err", err)
			return fmt.Errorf("stop existing addrinfo loop: %w", err)
		}
		delete(driver.address, serviceIDValue)
	}

	callbackHandle := cgo.NewHandle(addrInfoCallbackContext{
		driver:    driver,
		serviceID: serviceIDValue,
	})
	cHostName := C.CString(hostName)
	defer C.free(unsafe.Pointer(cHostName))

	callbackHandleValue := C.uintptr_t(callbackHandle)
	var result C.DNSServiceErrorType
	serviceRef := C.startAddrInfo(
		callbackHandleValue,
		C.uint32_t(interfaceIndex),
		cHostName,
		&result,
	)
	if result != C.kDNSServiceErr_NoError {
		callbackHandle.Delete()
		return dnsError("addrinfo", int32(result))
	}

	loop := newServiceLoop(serviceRef, callbackHandle, driver.stopChannel, "addrinfo")
	driver.address[serviceIDValue] = loop
	loop.start(func(err error) {
		driver.sink.fail(fmt.Errorf("addrinfo loop failed: %w", err))
	})
	return nil
}

func (driver *dnsSDDriver) stopServiceLoops(serviceIDValue string) error {
	driver.mutex.Lock()
	defer driver.mutex.Unlock()

	var stopError error
	if loop, exists := driver.resolves[serviceIDValue]; exists {
		stopError = errors.Join(stopError, loop.stop())
		delete(driver.resolves, serviceIDValue)
	}
	if loop, exists := driver.address[serviceIDValue]; exists {
		stopError = errors.Join(stopError, loop.stop())
		delete(driver.address, serviceIDValue)
	}
	return stopError
}

func newServiceLoop(
	serviceRef C.DNSServiceRef,
	handle cgo.Handle,
	stopChannel <-chan struct{},
	name string,
) *serviceLoop {
	return &serviceLoop{
		ref:         serviceRef,
		handle:      handle,
		name:        name,
		stopChannel: stopChannel,
		done:        make(chan struct{}),
	}
}

func (loop *serviceLoop) start(onError func(error)) {
	logger := slog.Default().With("component", "discovery", "loop", loop.name)
	go func() {
		defer close(loop.done)
		defer func() {
			if recovered := recover(); recovered != nil {
				panicError := fmt.Errorf("dns-sd service loop panic: %v", recovered)
				logger.Error("dns-sd service loop panicked", "err", panicError)
			}
		}()

		loop.run(onError)
	}()
}

func (loop *serviceLoop) stop() error {
	C.DNSServiceRefDeallocate(loop.ref)
	<-loop.done
	loop.handle.Delete()
	return nil
}

func familyFromInt(family int) AddressFamily {
	switch family {
	case unix.AF_INET:
		return AddressFamilyIPv4
	case unix.AF_INET6:
		return AddressFamilyIPv6
	default:
		return AddressFamilyUnspecified
	}
}

func dnsError(operation string, errorCode int32) error {
	return fmt.Errorf("%s dns-sd error %d", operation, errorCode)
}

func (loop *serviceLoop) isStopped() bool {
	select {
	case <-loop.stopChannel:
		return true
	default:
		return false
	}
}

func (loop *serviceLoop) socketFileDescriptor() (int, error) {
	fileDescriptor := int(C.DNSServiceRefSockFD(loop.ref))
	if fileDescriptor >= 0 {
		return fileDescriptor, nil
	}
	return 0, errors.New("dns-sd socket file descriptor unavailable")
}

func (loop *serviceLoop) pollDescriptor() ([]unix.PollFd, error) {
	fileDescriptor, err := loop.socketFileDescriptor()
	if err != nil {
		return nil, err
	}

	return []unix.PollFd{{
		Fd:     int32(fileDescriptor),
		Events: unix.POLLIN,
	}}, nil
}

func (loop *serviceLoop) run(onError func(error)) {
	pollDescriptor, err := loop.pollDescriptor()
	if err != nil {
		if loop.isStopped() {
			return
		}
		onError(err)
		return
	}

	for {
		if loop.isStopped() {
			return
		}

		if err = loop.poll(pollDescriptor); err != nil {
			if errors.Is(err, unix.EINTR) {
				continue
			}
			if loop.isStopped() {
				return
			}
			onError(fmt.Errorf("poll dns-sd socket: %w", err))
			return
		}
		if !loop.hasReadableEvent(pollDescriptor) {
			continue
		}
		if err = loop.processResult(); err != nil {
			if loop.isStopped() {
				return
			}
			onError(err)
			return
		}
	}
}

func (loop *serviceLoop) poll(pollDescriptor []unix.PollFd) error {
	logger := slog.Default().With("component", "discovery", "loop", loop.name)
	_, err := unix.Poll(pollDescriptor, int((250 * time.Millisecond).Milliseconds()))
	if err != nil {
		logger.Error("dns-sd socket poll failed", "err", err)
		return fmt.Errorf("poll dns-sd socket: %w", err)
	}
	return nil
}

func (loop *serviceLoop) hasReadableEvent(pollDescriptor []unix.PollFd) bool {
	return pollDescriptor[0].Revents&unix.POLLIN != 0
}

func (loop *serviceLoop) processResult() error {
	result := C.DNSServiceProcessResult(loop.ref)
	if result == C.kDNSServiceErr_NoError {
		return nil
	}
	return dnsError("process result", int32(result))
}

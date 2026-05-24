//go:build darwin

package discovery

/*
#include <dns_sd.h>
#include <stdint.h>
#include <netinet/in.h>
*/
import "C"

import (
	"errors"
	"net"
	"runtime/cgo"
	"unsafe"

	"golang.org/x/sys/unix"
)

// GoBrowseCallback is the cgo-exported DNSServiceBrowse callback entrypoint.
//
//export GoBrowseCallback
func GoBrowseCallback(
	handle C.uintptr_t,
	flags C.DNSServiceFlags,
	interfaceIndex C.uint32_t,
	errorCode C.DNSServiceErrorType,
	serviceName *C.char,
	serviceType *C.char,
	domain *C.char,
) {
	value := cgo.Handle(handle).Value()
	callbackContext, ok := value.(browseCallbackContext)
	if !ok {
		return
	}
	event := dnsSDEvent{
		kind: dnsSDEventBrowse,
		browse: dnsSDBrowseEvent{
			flags:          uint32(flags),
			interfaceIndex: uint32(interfaceIndex),
			errorCode:      int32(errorCode),
			serviceName:    C.GoString(serviceName),
			serviceType:    C.GoString(serviceType),
			domain:         C.GoString(domain),
		},
	}
	select {
	case <-callbackContext.driver.stopChannel:
		return
	default:
	}

	select {
	case <-callbackContext.driver.stopChannel:
	case callbackContext.driver.events <- event:
	default:
		callbackContext.driver.sink.fail(errors.New("dns-sd browse event queue is full"))
	}
}

// GoResolveCallback is the cgo-exported DNSServiceResolve callback entrypoint.
//
//export GoResolveCallback
func GoResolveCallback(
	handle C.uintptr_t,
	flags C.DNSServiceFlags,
	interfaceIndex C.uint32_t,
	errorCode C.DNSServiceErrorType,
	hostName *C.char,
	port C.uint16_t,
) {
	_ = flags
	value := cgo.Handle(handle).Value()
	callbackContext, ok := value.(resolveCallbackContext)
	if !ok {
		return
	}
	event := dnsSDEvent{
		kind: dnsSDEventResolve,
		resolve: dnsSDResolveEvent{
			serviceID:      callbackContext.serviceID,
			interfaceIndex: uint32(interfaceIndex),
			errorCode:      int32(errorCode),
			hostName:       C.GoString(hostName),
			port:           uint16(port),
		},
	}
	select {
	case <-callbackContext.driver.stopChannel:
		return
	default:
	}

	select {
	case <-callbackContext.driver.stopChannel:
	case callbackContext.driver.events <- event:
	default:
		callbackContext.driver.sink.fail(errors.New("dns-sd resolve event queue is full"))
	}
}

// GoAddrInfoCallback is the cgo-exported DNSServiceGetAddrInfo callback entrypoint.
//
//export GoAddrInfoCallback
func GoAddrInfoCallback(
	handle C.uintptr_t,
	flags C.DNSServiceFlags,
	interfaceIndex C.uint32_t,
	errorCode C.DNSServiceErrorType,
	family C.int,
	address unsafe.Pointer,
) {
	_ = interfaceIndex
	value := cgo.Handle(handle).Value()
	callbackContext, ok := value.(addrInfoCallbackContext)
	if !ok {
		return
	}

	renderedAddress := ""
	if address != nil {
		switch int(family) {
		case unix.AF_INET:
			rawAddress := (*unix.RawSockaddrInet4)(address)
			renderedAddress = net.IP(rawAddress.Addr[:]).String()
		case unix.AF_INET6:
			rawAddress := (*unix.RawSockaddrInet6)(address)
			renderedAddress = net.IP(rawAddress.Addr[:]).String()
		}
	}
	event := dnsSDEvent{
		kind: dnsSDEventAddrInfo,
		addrInfo: dnsSDAddrInfoEvent{
			serviceID: callbackContext.serviceID,
			flags:     uint32(flags),
			errorCode: int32(errorCode),
			family:    int(family),
			address:   renderedAddress,
		},
	}
	select {
	case <-callbackContext.driver.stopChannel:
		return
	default:
	}

	select {
	case <-callbackContext.driver.stopChannel:
	case callbackContext.driver.events <- event:
	default:
		callbackContext.driver.sink.fail(errors.New("dns-sd addrinfo event queue is full"))
	}
}

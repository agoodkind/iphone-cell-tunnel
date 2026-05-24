package tunnel

/*
#include <sys/ioctl.h>
#include <errno.h>

static int celltunnel_ioctl(int fd, unsigned long request, void *argument) {
	return ioctl(fd, request, argument);
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

func nativeIoctl(fd int, request uintptr, pointer unsafe.Pointer) error {
	if fd < 0 {
		return fmt.Errorf("invalid file descriptor: %d", fd)
	}

	result, err := C.celltunnel_ioctl(C.int(fd), C.ulong(request), pointer)
	if result == 0 {
		return nil
	}
	if err != nil {
		return err
	}
	return fmt.Errorf("ioctl failed for request: %d", request)
}

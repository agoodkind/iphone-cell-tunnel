// Package usbmuxd is a thin wrapper over go-ios that exposes the two things
// celltunneld needs from Apple's USB multiplexer: enumerate attached iPhones
// and dial a TCP port on one. It returns plain [net.Conn] streams so the relay
// client can treat the usbmuxd transport the same as a raw TCP dial.
package usbmuxd

import (
	"fmt"
	"log/slog"
	"net"

	"github.com/danielpaulus/go-ios/ios"
)

var logger = slog.Default().With("component", "usbmuxd")

// Device captures the minimum identity we need for selection and logging.
type Device struct {
	DeviceID       int
	UDID           string
	ConnectionType string
}

// ListDevices returns the iPhones that usbmuxd reports as attached.
func ListDevices() ([]Device, error) {
	rawDevices, err := ios.ListDevices()
	if err != nil {
		logger.Error("usbmuxd list devices failed", "err", err)
		return nil, fmt.Errorf("usbmuxd list devices: %w", err)
	}
	devices := make([]Device, 0, len(rawDevices.DeviceList))
	for _, entry := range rawDevices.DeviceList {
		devices = append(devices, Device{
			DeviceID:       entry.DeviceID,
			UDID:           entry.Properties.SerialNumber,
			ConnectionType: entry.Properties.ConnectionType,
		})
	}
	logger.Debug("usbmuxd list devices succeeded", "count", len(devices))
	return devices, nil
}

// Dial opens a TCP stream through usbmuxd to the given port on the device.
func Dial(deviceID int, port uint16) (net.Conn, error) {
	usbmuxConnection, err := ios.NewUsbMuxConnectionSimple()
	if err != nil {
		logger.Error("usbmuxd open control connection failed", "err", err, "device_id", deviceID, "port", port)
		return nil, fmt.Errorf("usbmuxd open control connection: %w", err)
	}
	if err := usbmuxConnection.Connect(deviceID, port); err != nil {
		logger.Error("usbmuxd connect failed", "err", err, "device_id", deviceID, "port", port)
		return nil, fmt.Errorf("usbmuxd connect device=%d port=%d: %w", deviceID, port, err)
	}
	deviceConnection := usbmuxConnection.ReleaseDeviceConnection()
	netConnection := deviceConnection.Conn()
	if netConnection == nil {
		_ = deviceConnection.Close()
		err := fmt.Errorf("usbmuxd device connection missing net.Conn for device=%d port=%d", deviceID, port)
		logger.Error("usbmuxd device connection missing net.Conn", "err", err, "device_id", deviceID, "port", port)
		return nil, err
	}
	logger.Debug("usbmuxd connect succeeded", "device_id", deviceID, "port", port)
	return netConnection, nil
}

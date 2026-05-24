//go:build !darwin

package discovery

import "errors"

func newDriver(sink eventSink) (driver, error) {
	_ = sink
	return nil, errors.New("native dns-sd discovery is only available on darwin")
}

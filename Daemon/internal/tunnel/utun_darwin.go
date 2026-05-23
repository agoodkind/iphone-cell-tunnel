package tunnel

import "runtime"

func checkUTUNSupport() string {
	if runtime.GOOS != "darwin" {
		logger.Error("utun unavailable on non-darwin host", "err", errUnsupportedPlatform, "os", runtime.GOOS)
		return "missing"
	}

	logger.Info("utun support available", "os", runtime.GOOS)
	return "available"
}

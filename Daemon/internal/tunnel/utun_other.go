//go:build !darwin

package tunnel

func checkUTUNSupport() string {
	logger.Error("utun unavailable on unsupported build target", "err", errUnsupportedPlatform)
	return "missing"
}

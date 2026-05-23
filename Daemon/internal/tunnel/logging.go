package tunnel

import "log/slog"

var logger = slog.Default().With("component", "tunnel")

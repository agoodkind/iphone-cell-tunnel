# Temporary MVP Notes

This file is temporary and should not be treated as durable project documentation.

## Networking

- Cell Tunnel should prefer IPv6 for peer discovery, relay selection, tunnel endpoints, display, and diagnostics.
- Cell Tunnel should keep IPv4 support as dual-stack fallback behavior.
- Cell Tunnel should connect from the Mac to the iPhone relay over IPv6 when an IPv6 relay endpoint is available.
- Cell Tunnel should display the selected Mac-to-iPhone relay address family and endpoint.

## Interface Design

- Cell Tunnel should redesign the iPhone and Mac interfaces through explicit storyboards before implementation.
- Cell Tunnel should align both interfaces with Apple Human Interface Guidelines.
- Cell Tunnel should treat spacing, hierarchy, typography, labels, button count, states, and error presentation as first-order design work.
- Cell Tunnel should never require a user to manually copy or paste a discovered iPhone relay endpoint.
- Cell Tunnel should automatically select the best discovered iPhone relay endpoint when exactly one valid endpoint is available.
- Cell Tunnel should make endpoint selection explicit when more than one valid iPhone relay endpoint is available.
- Cell Tunnel should use one primary action per setup step and hide unavailable actions until their prerequisites are satisfied.
- Cell Tunnel should replace internal daemon, socket, route, counter, and peer labels with user-facing setup state.
- Cell Tunnel should show diagnostic details in a separate advanced view instead of the primary setup flow.
- Cell Tunnel should use the same connection terms on the Mac and iPhone so that each screen describes the same runtime state.
- Cell Tunnel should display a clear next action when the daemon is not installed, not approved, not running, or unreachable.
- Cell Tunnel should not show conflicting setup state, such as a resolved relay list next to an empty selected relay field.

## CLI Control

- Cell Tunnel should support CLI-first MVP testing through simple `celltunneld` flags.
- Cell Tunnel should support `celltunneld status` for daemon state.
- Cell Tunnel should support `celltunneld start --config <path> --relay <host:port>` for tunnel start.
- Cell Tunnel should support `celltunneld stop` for tunnel stop.
- Cell Tunnel should keep verbose daemon internals out of default CLI output.

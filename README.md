# Cell Tunnel

Internal dual-stack iPhone cellular tunnel prototype.

The project contains:

- `CellTunnelPhone`: foreground iOS relay app.
- `CellTunnelMac`: macOS control app.
- `celltunneld`: macOS tunnel daemon scaffold.
- `CellTunnelCore`: shared relay protocol types used by both Swift apps.

This prototype is not Personal Hotspot and is not a kernel NAT router. The Mac
side owns packet capture and flow translation, and the iPhone side originates
matching IPv4 and IPv6 traffic over cellular.

## Current status

The Swift apps and daemon command surface are scaffolded first. Privileged
`utun`, routing, gVisor netstack integration, and physical iPhone cellular ICMP
validation are intentionally separated behind daemon boundaries so the project
can build before it mutates local networking.

## Build

```sh
./script/build_and_run.sh --build-only
```

The build script generates `CellTunnel.xcodeproj`, builds the macOS app, builds
the iOS app for a generic iOS Simulator destination, and runs the Go daemon
tests. Set `IOS_SIMULATOR_DESTINATION` if you want a concrete simulator, for
example `platform=iOS Simulator,name=iPhone 17 Pro`.

## Daemon dry-run

```sh
go run ./Daemon/cmd/celltunneld start --dry-run
go run ./Daemon/cmd/celltunneld status
go run ./Daemon/cmd/celltunneld check
```

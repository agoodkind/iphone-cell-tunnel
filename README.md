# Cell Tunnel

Cell Tunnel is an internal dual-stack iPhone cellular tunnel prototype.

## Components

- `CellTunnelPhone` is the foreground iOS relay app.
- `CellTunnelMac` is the macOS control app and typed IPC client.
- `celltunneld` is the macOS tunnel daemon, gRPC control server, and DNS-SD discovery owner.
- `celltunnelctl` is the Swift CLI typed IPC client.
- `CellTunnelCore` contains shared Swift relay protocol types and generated control IPC bindings.
- `CellTunnelLog` contains shared Swift logging categories.

## Documentation

- [MVP WireGuard Relay Architecture](docs/architecture/mvp-wireguard-relay.md)
- [Engineering Rules](docs/development/engineering-rules.md)
- [Tooling](docs/development/tooling.md)
- [Signing](docs/development/signing.md)
- [MVP Device Check](docs/runbooks/mvp-device-check.md)
- [MVP CLI Check](docs/runbooks/mvp-cli-check.md)

## Build

```sh
make build
```

## Run

```sh
make run TARGET=mac
make run TARGET=iphone
make run TARGET=iphone-simulator
```

## Install Or Deploy

```sh
make install TARGET=mac
make install TARGET=iphone
make install TARGET=iphone-simulator

make deploy TARGET=mac
make deploy TARGET=iphone
make deploy TARGET=iphone-simulator
```

## Verify

```sh
make lint
make log-audit
make go-audit
make test
make analyze
make build
make signing-check
```

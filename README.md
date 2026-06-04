# Cell Tunnel

Cell Tunnel routes a Mac's internet traffic through an iPhone's native cellular modem over WireGuard. See [docs/architecture.md](docs/architecture.md) for the data path and components.

## Build

Builds run lint and audit gates first. `TARGET` is required.

```sh
make build TARGET=mac CONFIG=Debug
make build TARGET=mac-catalyst CONFIG=Debug
make build TARGET=iphone-device CONFIG=Debug
make build TARGET=iphone-simulator CONFIG=Debug
```

## Signing

The iOS device build uses automatic signing. Registering the App Group and Network
Extension capabilities needs an App Store Connect API key, supplied through
`APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, and either `APPLE_NOTARY_KEY_PATH`
(a `.p8` path) or `APPLE_NOTARY_KEY_BASE64`. Set these in the environment or in
`Config/local.signing.env` (gitignored); copy `Config/local.signing.env.example` to
start. The `.p8` key lives outside the repo. With no key set, the build falls back
to the interactive Xcode account.

The macOS targets sign from `Config/local.xcconfig` (`DEVELOPMENT_TEAM`,
`CODE_SIGN_IDENTITY`, `CODE_SIGN_STYLE`).

## Install and run

Install the Mac side, then install and launch the iPhone app:

```sh
make install-mac CONFIG=Debug
make iphone-install CONFIG=Debug
```

Drive the tunnel with `celltunnelctl`. Each command returns after one round-trip to the agent:

```sh
celltunnelctl devices                 # list discovered relay devices
celltunnelctl select <n|serviceID>    # select a relay by 1-based index or service id
celltunnelctl start --config <path>   # start the tunnel (optional: --relay <host:port>)
celltunnelctl status                  # print current tunnel status
celltunnelctl stop                    # stop the tunnel
```

The iPhone app is always-on. It auto-starts the relay on launch and on returning to the foreground, with no Start button, and shows a minimal status screen with relay state, cellular egress, throughput, and dropped counts.

The Mac Catalyst build shows the same status screen, populated from the agent over XPC. It is a viewer: control still happens through `celltunnelctl`. Build it with `make build TARGET=mac-catalyst CONFIG=Debug`.

## Requirements

- Swift 6, targeting iOS 26 and macOS 15.
- Tuist, managed by mise.
- A paid Apple Developer account, required for the Network Extension entitlements.

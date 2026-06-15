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

Bring the tunnel up from a WireGuard config. The Mac VPN connects immediately, and the routes install once the iPhone dials in over the link:

```sh
swift Tools/cell-tunnel-dev.swift relay-up --config <path>   # bring the tunnel up end to end
swift Tools/cell-tunnel-dev.swift relay-status               # full state dump with a drift verdict
swift Tools/cell-tunnel-dev.swift relay-down                 # stop the tunnel
```

The agent owns one config library, so a config you start is stored once and reused. Manage it from the Mac app's Configs card or with `celltunnelctl configs`:

```sh
celltunnelctl configs list                 # list stored configs, active one flagged
celltunnelctl configs import <path>        # import, activate, and start a config
celltunnelctl configs activate <name|id>   # switch the running tunnel to a stored config
```

Run `celltunnelctl --help` for the full command set, including `status`, `stop`, and the `peers`/`select` egress roster used when more than one iPhone is dialed in.

The iPhone app is always-on. It auto-starts the relay on launch and on returning to the foreground, with no Start button, and shows a status screen with relay state, cellular egress, throughput, and dropped counts.

The Mac Catalyst build shows the same status screen, filled from the agent over XPC, and manages the config library: import, activate, edit, rename, and delete. The agent owns the tunnel; the app drives it over XPC.

## Requirements

- Swift 6, targeting iOS 26 and macOS 15.
- Tuist, managed by mise.
- A paid Apple Developer account, required for the Network Extension entitlements.

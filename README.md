# Cell Tunnel

Cell Tunnel routes a Mac's internet traffic through an iPhone's native cellular modem over WireGuard. See [docs/run.md](docs/run.md) for what running it takes today, and [docs/architecture.md](docs/architecture.md) for the data path and components.

## Build

`make help` lists engine targets, then the named Cell Tunnel targets.

`make build` and `make build-all` compile every platform through CellTunnelDev.

Named targets build one platform:

```sh
make build-mac
make build-catalyst
make build-iphone
make build-iphone-sim
make build-daemon
```

Continuous integration builds every platform in one Verify job, signs each
product, and verifies each runnable product's signature.

`CONFIG` defaults to `Debug`. Pass `CONFIG=Release` when needed.

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

Continuous integration signs differently, because its runners are not registered
devices and development provisioning requires one. `make ci-provision` runs fastlane
to create or renew one App Store distribution profile per target through the App Store
Connect API key, and the build signs manually against those profiles. `Project.swift`
pins each profile by name when `TUIST_DEVELOPER_ID_SIGNING` is set. See
[fastlane/Fastfile](fastlane/Fastfile).

## Install and run

Install the Mac side, then install and launch the iPhone app:

```sh
make install-mac
make iphone-install
```

Run the Catalyst app from a built product:

```sh
make run-catalyst
```

Bring the tunnel up from a WireGuard config. The Mac VPN connects immediately, and the routes install once the iPhone dials in over the link:

```sh
make relay-up WG_CONFIG=<path>
make relay-status
make relay-down
```

Anything not covered by a named Make target stays on the underlying tool: `swift Tools/cell-tunnel-dev.swift <command>` (run with no args for the full list).

The agent owns one config library, so a config you start is stored once and reused. Manage it from the Mac app's Configs card or with `celltunnelctl configs`:

```sh
celltunnelctl configs list                 # list stored configs, active one flagged
celltunnelctl configs import <path>        # store a config and mark it active; starts nothing
celltunnelctl configs activate <name|id>   # mark a stored config active; starts nothing
```

Run `celltunnelctl --help` for the full command set, including `status`, `stop`, and the `peers`/`select` egress roster used when more than one iPhone is dialed in.

The iPhone app is always-on. It auto-starts the relay on launch and on returning to the foreground, with no Start button, and shows a status screen with relay state, cellular egress, throughput, and dropped counts.

The Mac Catalyst build shows the same status screen, filled from the agent over XPC, and manages the config library: import, activate, edit, rename, and delete. The agent owns the tunnel; the app drives it over XPC.

## Requirements

- Swift 6, targeting iOS 26 and macOS 15.
- Tuist, managed by mise.
- A paid Apple Developer account, required for the Network Extension entitlements.

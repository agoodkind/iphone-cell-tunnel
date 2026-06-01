# Cell Tunnel

Cell Tunnel routes a Mac's internet traffic through an iPhone's native cellular modem over WireGuard. The Mac encrypts each outbound IP packet with WireGuard (wireguard-go plus a custom relay bind inside a `NEPacketTunnelProvider`), ships the encrypted UDP datagram over the USB or Thunderbolt link to the iPhone app, and the iPhone forwards each datagram out the cellular interface (`pdp_ip0`) to a hosted WireGuard server, which is the internet exit. Replies retrace the same path.

## Components

- `celltunnelctl` is a thin command-line control client that talks over XPC to the agent.
- `CellTunnelAgent` is a user-space background agent (an `LSUIElement` LaunchAgent registered via `SMAppService.agent`) that owns the `NETunnelProviderManager`, runs continuous Bonjour discovery of iPhone relays, persists the selected device, and embeds the macOS tunnel provider extension.
- The tunnel provider extension is the `NEPacketTunnelProvider` embedded in the agent. It owns the data path: WireGuard, the relay transport to the iPhone, and the typed control channel.
- The iPhone relay app runs the relay forwarder and a control listener, binds its cellular egress, and forwards encrypted datagrams between the Mac and the WireGuard server.
- The same app target also builds for Mac through Mac Catalyst, sharing the iPhone's SwiftUI screens. The Mac build is a read-only front-end to the agent, reaching it over XPC and showing the Mac tunnel's status; it owns no tunnel of its own.

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

The Mac Catalyst build shows the same status screen and the ladybug developer console, populated from the agent over XPC. It is a viewer: control still happens through `celltunnelctl`. Build it with `make build TARGET=mac-catalyst CONFIG=Debug`.

## Requirements

- Swift 6, targeting iOS 26 and macOS 15.
- Tuist, managed by mise.
- A paid Apple Developer account, required for the Network Extension entitlements.

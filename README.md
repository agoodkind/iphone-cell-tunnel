# Cell Tunnel

Cell Tunnel routes a Mac's internet traffic through an iPhone's native cellular modem over WireGuard. The Mac encrypts each outbound IP packet with WireGuard (wireguard-go plus a custom relay bind inside a `NEPacketTunnelProvider`), ships the encrypted UDP datagram over the USB or Thunderbolt link to the iPhone app, and the iPhone forwards each datagram out the cellular interface (`pdp_ip0`) to a hosted WireGuard server, which is the internet exit. Replies retrace the same path.

## Components

- `celltunnelctl` is a thin command-line control client that talks over XPC to the agent.
- `CellTunnelAgent` is a user-space background agent (an `LSUIElement` LaunchAgent registered via `SMAppService.agent`) that owns the `NETunnelProviderManager`, runs continuous Bonjour discovery of iPhone relays, persists the selected device, and embeds the macOS tunnel provider extension.
- The tunnel provider extension is the `NEPacketTunnelProvider` embedded in the agent. It owns the data path: WireGuard, the relay transport to the iPhone, and the typed control channel.
- The iPhone relay app runs the relay forwarder and a control listener, binds its cellular egress, and forwards encrypted datagrams between the Mac and the WireGuard server.

## Build

Builds run lint and audit gates first. `TARGET` is required.

```sh
make build TARGET=mac CONFIG=Debug
make build TARGET=iphone-device CONFIG=Debug
make build TARGET=iphone-simulator CONFIG=Debug
```

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

## Requirements

- Swift 6, targeting iOS 26 and macOS 15.
- Tuist, managed by mise.
- A paid Apple Developer account, required for the Network Extension entitlements.

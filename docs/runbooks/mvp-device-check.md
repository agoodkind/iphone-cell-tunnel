# MVP Device Check

This runbook verifies the physical-device MVP packet path. The CLI walkthrough is the canonical
path and matches the dev loop. The GUI walkthrough exercises the launchd-managed install path.

## Prerequisites

- A connected physical iPhone, unlocked, with `CellTunnelPhone` installed.
- A hosted WireGuard server that forwards IPv4 and IPv6 traffic.
- A local WireGuard config file for the Mac daemon. The smoke file lives at
  `/Users/agoodkind/Desktop/wireguard-export/example.com only.conf`.
- A Mac that can reach the iPhone over USB and through Apple's `usbmuxd`.

## CLI Procedure

1. Build the daemon and CLI with `swift Tools/cell-tunnel-dev.swift build daemon`. The wrapper
   runs lint, log audit, and Go audit before any compile, then prints SHA256 fingerprints for
   `Products/celltunneld` and `Products/celltunnelctl`.
2. Build and launch `CellTunnelPhone` on the iPhone with `swift Tools/cell-tunnel-dev.swift
   activate iphone`. The app auto-starts its relay listener.
3. Unload any launchd-managed daemon with `sudo launchctl bootout system/io.goodkind.celltunneld`.
   Skip this step if no launchd-managed daemon is loaded.
4. Start the freshly built daemon under sudo in a dedicated terminal:
   `sudo Products/celltunneld serve`.
5. Run `Products/celltunnelctl probe` and note the port for the iPhone relay service.
6. Read the iPhone UDID with `ideviceinfo -k UniqueDeviceID`.
7. Start the tunnel through usbmuxd:
   `Products/celltunnelctl start --config "/Users/agoodkind/Desktop/wireguard-export/example.com only.conf" --relay "usbmuxd:<UDID>:<port>"`.
8. Run `Products/celltunnelctl status` and confirm `running=true`, `routes=installed`, and an
   `activeRelayEndpoint` that starts with `usbmuxd:`.
9. Send IPv4 traffic with `ping -c 5 208.67.222.222`.
10. Send IPv6 traffic with `ping6 -c 5 2620:119:35::35`.
11. Stream iPhone logs with `swift Tools/cell-tunnel-dev.swift iphone-logs --app` and confirm
    `interface: pdp_ip0[lte]` plus `uses cell` activity for the same time window.
12. Stop the tunnel with `Products/celltunnelctl stop`.
13. Confirm `Products/celltunnelctl status` reports `running=false` and `routes=not-installed`.

## GUI Procedure

1. Build the signed bundle with `swift Tools/cell-tunnel-dev.swift build mac`. The wrapper signs
   the daemon and the app bundle, then prints fingerprints for the source binary, the bundle copy,
   and the installed copy.
2. Launch the Mac app with `swift Tools/cell-tunnel-dev.swift activate mac`.
3. Launch the iPhone app with `swift Tools/cell-tunnel-dev.swift activate iphone`.
4. Approve the daemon from the Mac app. The first run shows the System Settings prompt and a
   TouchID confirmation.
5. Start the iPhone relay from `CellTunnelPhone`.
6. Select the WireGuard config file in `CellTunnelMac`.
7. Start relay discovery in `CellTunnelMac`.
8. Select the resolved `_cellrelay._tcp` iPhone relay service in `CellTunnelMac`.
9. Start the tunnel from `CellTunnelMac`.
10. Confirm daemon status reports `running=true` and `routes=installed`.
11. Confirm the iPhone app reports the hosted WireGuard UDP state as ready.
12. Send IPv4 traffic from the Mac through the tunnel.
13. Send IPv6 traffic from the Mac through the tunnel.
14. Stop the tunnel from `CellTunnelMac`.
15. Confirm daemon status reports `running=false` and `routes=not-installed`.

## Acceptance Criteria

- Mac IPv4 traffic returns through the hosted WireGuard server.
- Mac IPv6 traffic returns through the hosted WireGuard server.
- The iPhone relay stays foregrounded during traffic flow.
- The relay counters increase for Mac-to-server and server-to-Mac datagrams.
- The same smoke targets pass after a `stop` and `start` cycle without rebuilding.
- Tunnel stop removes routes and closes `utun`.
- Relay disconnect removes routes, closes `utun`, and reports the runtime error in daemon status.

# MVP Device Check

This runbook verifies the physical-device MVP packet path.

## Prerequisites

- A signed `CellTunnelMac.app`.
- A running `celltunneld` launch daemon.
- A foreground `CellTunnelPhone` app.
- A hosted WireGuard server that forwards IPv4 and IPv6 traffic.
- A local WireGuard config file for the Mac daemon.
- A Mac and iPhone that can reach each other over the local relay channel.

## Procedure

1. Build everything with `make build`.
2. Launch the Mac app with `make run TARGET=mac`.
3. Launch the iPhone app with `make run TARGET=iphone`.
4. Install or approve the daemon from the Mac app.
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
- Tunnel stop removes routes and closes `utun`.
- Relay disconnect removes routes, closes `utun`, and reports the runtime error in daemon status.

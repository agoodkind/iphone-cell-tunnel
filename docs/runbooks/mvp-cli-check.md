# MVP CLI Check

This runbook verifies the physical-device MVP packet path through `celltunnelctl` commands.

## Prerequisites

- `CellTunnelPhone` is running in the foreground on the iPhone.
- `CellTunnelPhone` shows the relay as running.
- `CellTunnelPhone` shows IPv6 as ready.
- `CellTunnelPhone` shows IPv4 as ready.
- `celltunneld` is installed as the macOS launch daemon.
- `/var/run/io.goodkind.celltunnel/control.sock` exists on the Mac.
- The Mac has a local exported WireGuard `.conf` file.
- The hosted WireGuard server forwards IPv4 and IPv6 traffic.

## Commands

Check daemon status:

```sh
Products/celltunnelctl status
```

Start daemon-owned relay discovery:

```sh
Products/celltunnelctl start-discovery
Products/celltunnelctl discover
```

Start the tunnel:

```sh
Products/celltunnelctl start --config "/path/to/wireguard.conf"
```

Start the tunnel with an explicit relay override:

```sh
Products/celltunnelctl start --config "/path/to/wireguard.conf" --relay "[fd00::44]:51820"
```

Stop the tunnel:

```sh
Products/celltunnelctl stop
```

## Acceptance Criteria

- `Products/celltunnelctl status` reports `running=true`.
- `Products/celltunnelctl status` reports `routes=installed`.
- `Products/celltunnelctl discover` lists the resolved relay service and selected endpoint.
- The iPhone relay reports Mac peer activity after `Products/celltunnelctl start`.
- IPv4 traffic from the Mac returns through the hosted WireGuard server.
- IPv6 traffic from the Mac returns through the hosted WireGuard server.
- `Products/celltunnelctl stop` reports `running=false`.
- `Products/celltunnelctl stop` removes the tunnel routes.

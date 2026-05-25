# MVP CLI Check

This runbook verifies the physical-device MVP packet path with `celltunnelctl` commands and the
sudo-run daemon. The canonical Mac to iPhone transport is `usbmuxd:<UDID>:<port>`.

## Prerequisites

- `CellTunnelPhone` runs in the foreground on the iPhone.
- `CellTunnelPhone` shows the relay as running, IPv4 ready, and IPv6 ready.
- The iPhone is connected to the Mac over USB and unlocked.
- The hosted WireGuard server forwards IPv4 and IPv6 traffic.
- The Mac has a local exported WireGuard `.conf` file.
- `Products/celltunneld` and `Products/celltunnelctl` exist (`swift Tools/cell-tunnel-dev.swift
  build daemon` produces both).
- The iPhone UDID is on hand. `ideviceinfo -k UniqueDeviceID` prints it.

## Start the daemon under sudo

The daemon needs root for `utun` and the routing socket. The dev loop runs the freshly built binary
under `sudo` and skips the launchd registration.

If a launchd-managed daemon is already loaded, remove it so the two copies do not fight over the
control socket:

```sh
sudo launchctl bootout system/io.goodkind.celltunneld
```

Start the freshly built daemon in a dedicated terminal:

```sh
sudo /Users/agoodkind/Sites/iphone-cell-tunnel/Products/celltunneld serve
```

The daemon creates `/var/run/io.goodkind.celltunnel/` if missing, listens on `control.sock`, and
chmods the socket to `0666`. The daemon defaults to `slog.LevelDebug`. Override at process start
with `CELL_TUNNEL_LOG_LEVEL=debug|info|warn|warning|error`.

## Confirm the daemon is reachable

```sh
Products/celltunnelctl status
```

Expect `running=false`. That proves the CLI reaches the sudo-run daemon over the control socket.

## Find the iPhone relay port

`Products/celltunnelctl discover` starts daemon-owned discovery and lists every resolved relay
service with its preferred endpoint. Each `service=...` line ends with `host:port`. Note the port
number for the iPhone service.

```sh
Products/celltunnelctl discover
```

## Start the tunnel through usbmuxd

The canonical CLI path passes the usbmuxd endpoint explicitly on `start`:

```sh
Products/celltunnelctl start \
    --config "/Users/agoodkind/Desktop/wireguard-export/example.com only.conf" \
    --relay "usbmuxd:00008150-000249060A00401C:<port>"
```

Replace the UDID with the value from `ideviceinfo`. Replace `<port>` with the port from
`discover`.

An alternate two-step path stores a discovered service in the daemon's selection slot and starts
without `--relay`:

```sh
Products/celltunnelctl select <service-id>
Products/celltunnelctl start --config "/Users/agoodkind/Desktop/wireguard-export/example.com only.conf"
```

`<service-id>` is the value printed by `discover`. The two-step path uses the discovered endpoint
verbatim, which for a bonjour-resolved iPhone is link-local IPv6 over USB-NCM. That transport dies
at 18 seconds. The two-step path is fine for simulator runs and for testing daemon plumbing. The
usbmuxd endpoint stays the canonical transport for physical-device smoke tests.

## Verify the tunnel

```sh
Products/celltunnelctl status
```

Expect `running=true`, `routes=installed`, and an `activeRelayEndpoint` that contains the
`usbmuxd:` prefix.

## Smoke targets

```sh
ping -c 5 208.67.222.222
ping6 -c 5 2620:119:35::35
curl -v https://208.67.222.222/
curl -v -g 'https://[2620:119:35::35]/'
```

Pings should return replies. Curl should complete a TLS handshake to each address. The HTTP body
can be a 404 or similar.

Wait past 20 seconds and ping again. The usbmuxd transport stays up. The previous
TCP-over-link-local path dies at exactly 18 seconds; see `docs/temporary/temporary-mvp-notes.md`
for the diagnosis.

## Stop the tunnel

```sh
Products/celltunnelctl stop
```

Expect `running=false` and `routes=not-installed`. The smoke IPs no longer route through `utun*`.

## Acceptance Criteria

- `Products/celltunnelctl start` returns a status snapshot with `running=true` and
  `routes=installed`.
- `route -n get 208.67.222.222` and `route -n get -inet6 2620:119:35::35` name a `utun*` interface
  during the session.
- `ping -c 5 208.67.222.222` returns five replies.
- `ping6 -c 5 2620:119:35::35` returns five replies.
- The iPhone log stream shows `interface: pdp_ip0[lte]` and `uses cell` activity during the test
  (`swift Tools/cell-tunnel-dev.swift iphone-logs --app`).
- The same smoke targets pass after a `stop` and `start` cycle.
- `Products/celltunnelctl stop` removes the routes for both smoke IPs.

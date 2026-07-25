# All-traffic egress verification

All-traffic mode routes every destination through the Cell Tunnel relay, so the Mac's public egress for any site is the far-end provider, not a local uplink. This page defines the acceptance criterion and the checks that prove it. For bringing the relay up and reading relay state, see AGENTS.md.

## Acceptance criterion

With the relay on and the active config widened to `AllowedIPs = 0.0.0.0/0, ::/0`, the effective public egress for a destination that is not pinned in the scoped config must fall inside one accepted prefix per address family:

- IPv4: AT&T fiber `104.57.226.192/29` or Webpass `136.25.91.240/29`
- IPv6: AT&T fiber `2600:1700:2f71:c80::/60` or Webpass `2604:5500:c271:bf00::/56`

The far end load-balances between the two providers, so each family may land in either of its two prefixes, and the two families may match different providers. Egress must not be a local uplink such as AT&T mobility, Comcast, or the LAN. Names must resolve over the tunnel, so sites load by hostname and not only by raw address.

The scoped config is the control: the same measurements in scoped mode return the local provider addresses, so the shift into the accepted far-end prefixes under all-traffic proves every destination egresses through the far end.

## Checks

Bring the relay up and confirm `relay-status` shows `routes=installed` before measuring, since a check before the routes install measures nothing through the tunnel. See AGENTS.md for bring-up.

### The tunnel owns the primary default route

Run `route -n get default` and `route -n get -inet6 default`. Both report the Cell Tunnel `utun` interface. A physical interface winning means the tunnel installed its default route but is not primary, so non-scoped traffic leaks out the local uplink.

### Names resolve over the tunnel

Run `dscacheutil -q host -a name ifconfig.co`. It returns an `ip_address`. The all-traffic config publishes a resolver reachable through the tunnel through its `DNS =` line; without that line hostnames fail while raw addresses still work.

### Non-scoped egress lands in an accepted prefix

Run `curl -4 https://ifconfig.co` and `curl -6 https://ifconfig.co`. `ipv4.icanhazip.com`, `ipv6.icanhazip.com`, and `api.ipify.org` are equivalent sources. The IPv4 address falls in an accepted IPv4 prefix and the IPv6 address in an accepted IPv6 prefix.

Do not measure egress with `dig @<resolver>` when the resolver address is pinned in the scoped `AllowedIPs`, for example OpenDNS `208.67.222.222` or `2620:119:35::35`. That query tunnels even in scoped mode, so it cannot tell the two paths apart. Measure by hostname, or with a resolver not in the scoped set such as OpenDNS `208.67.222.220` and `2620:119:53::53`.

### The scoped control returns the local provider

Activate the scoped config and repeat the egress check. The same measurements return local-uplink addresses, which confirms the all-traffic shift is real and not a resolver artifact.

# Relay link self-heal: re-dial a present interface that lost its link

## Problem

When USB unplugs, the iPhone relay can fall to zero Mac links and never recover until USB returns. The phone keeps receiving from the WireGuard server over cellular and drops every downstream datagram because it has no egress link to the Mac.

This is starvation, not a storm. The earlier "2-second re-dial storm" framing is not what the live device does now.

## Evidence (live, one process run, PID 22024, 2026-06-08)

Wi-Fi egress works. On a USB unplug at 22:22:11:

```
22:22:11.436  relay path probe interfaces changed names=awdl0,en0
22:22:11.725  phone relay dropped link interface=en2   reason=receive-error links=3
22:22:11.726  phone relay dropped link interface=anpi0 reason=receive-error links=2
22:22:11.728  phone relay carrying link interface=en0  class=wifi-lan
```

For the next 70 seconds (22:22:11 to 22:23:21) carrying stayed `en0` with zero `no-live-egress-link` drops. The phone relayed downstream over Wi-Fi LAN to the Mac with no loss. USB-to-Wi-Fi failover is clean, no flap.

Starvation in an earlier window 22:15:52 to 22:17:56:

```
phone relay datagram to mac dropped error=no-live-egress-link   (every ~5s, links=0)
```

The link set had decayed to nothing and stayed there until the USB replug at 22:18:00 forced a fresh dial of all four interfaces.

Phase 1 (link class) holds in both windows: `en0` dials as `wifi-lan`, `awdl0` as `peer-to-peer`.

## Root cause

The phone re-dials a missing link only when the probe interface set changes.

- `reconcileOnQueue` runs on a probe report. It dials interfaces in the report that have no link.
- The probe fires on an interface set change, not on a link death.
- A link removed by error (`receive-error`, AWDL reap) while its interface stays present does not change the set, so `reconcile` never re-fires for it.
- `onHeartbeatTick` re-dials only present-but-silent links (`ticksSinceInbound >= staleLinkTickLimit`), not links that are gone from `macLinks`.

So a link can die on a still-present interface and nothing re-dials it. Repeat for each link and the set decays to zero, which starves egress until a set change (USB replug) forces a fresh dial.

A second latent defect compounds this: `lastKnownInterfaces` is add-only and never prunes vanished interfaces. Any re-dial driven from it without pruning would re-dial gone USB interfaces forever, which is the storm. The fix must prune so self-heal does not become a storm.

## Goal

Keep one link per currently-present interface, healed on a short interval, with no re-dial of an interface that has genuinely gone away.

## Decisions (locked)

- The probe interface set is the source of truth for "currently present."
- `lastKnownInterfaces` holds exactly the latest probe set, pruned when an interface leaves.
- Self-heal re-dials only interfaces in that pruned set that have no link.
- Discovery stays add-and-prune by probe set; a brief browse gap that does not change the set does not tear down a link (the existing add-only-on-membership behavior for AWDL flap is preserved at the link level, not the known-set level).

## Fix

The pure selection lands in CellTunnelCore; the wiring lands in `Sources/CellTunnelRelay/PhoneRelayForwarder+Link.swift`.

1. Prune the known set. In `reconcileOnQueue`, set `lastKnownInterfaces` to exactly the reported interfaces (drop any not in the report), instead of only adding. Gone interfaces leave the known set, so nothing re-dials them.

2. Re-dial missing links on the heartbeat. In `onHeartbeatTick`, take the interfaces from `interfacesNeedingRedial(known: lastKnownInterfaces, open: Set(macLinks.keys))` and `dialLink` each. This brings back an error-removed link on a present interface within one heartbeat interval (2s).

3. Keep the existing stale-link re-dial for present-but-silent links.

`reconcileOnQueue` already dials report interfaces missing a link; route it through the same selection so the dial logic is not duplicated.

## Pure seam for testing

Extract a pure function into CellTunnelCore next to `RelayLinkPolicy`, since `RelayMacInterface` and `RelayLinkClass` are CellTunnelCore types:

```
func interfacesNeedingRedial(
  known: [String: RelayMacInterface],
  open: Set<String>
) -> [RelayMacInterface]
```

It returns the `known` interfaces whose name is not in `open`. Both the heartbeat and reconcile use it. It has no Network dependency, so it is unit-testable off-device.

## Testing

Unit tests in `Tests/CellTunnelCoreTests`, alongside the existing `RelayLinkClassTests`:

1. `en0` present in `known`, `open` empty, returns `[en0]`.
2. `en0` present in both `known` and `open`, returns `[]`.
3. `en2` not in `known` (pruned), `open` empty, returns `[]` (no re-dial of a gone interface).
4. Mixed: `known = {en0, awdl0}`, `open = {awdl0}`, returns `[en0]`.

## Live verification (after redeploy)

1. Healthy on USB: links for en2/anpi0/en0/awdl0, carrying a wired USB interface.
2. Unplug USB: USB links drop, carrying moves to `en0` (wifi-lan), and stays. `no-live-egress-link` drops do not appear.
3. Hold unplugged 2 to 3 minutes: carrying stays `en0`, links do not decay to zero, egress keeps flowing.
4. Toggle iPhone Wi-Fi briefly: the en0 link is re-dialed and carrying recovers, without a cross-interface storm.
5. Replug USB: carrying returns to a wired USB interface.
6. Confirm carriage with the `relay-status` counter delta per `AGENTS.md` (mac_datagrams_from_mac and to_mac advance while carrying en0 unplugged).

## Out of scope

- The Mac agent reaper and heartbeat echo. The live log shows failover and Wi-Fi carriage already work; the agent side is not the defect.
- The Phase 3 UI churn work, already committed.
- The control-link failover question. Control stayed up over USB in these captures; revisit only if a capture shows control dropping.

## Files likely touched

- `Sources/CellTunnelCore/RelayPathEvaluation.swift` (the pure `interfacesNeedingRedial` helper)
- `Sources/CellTunnelRelay/PhoneRelayForwarder+Link.swift` (prune `lastKnownInterfaces`, heartbeat re-dial wiring)
- `Tests/CellTunnelCoreTests/` (a test file for the pure helper)
- Header and `// MARK: -` dividers preserved on every touched file. `make lint` stays green.

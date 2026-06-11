# Routing intent: one source of truth, default on, no drift

## Problem

The phone's Route traffic switch shows off while the agent is routing. Three copies of routing state exist and they drift:

- The agent holds `routingEnabled` in memory. It resets to false on every restart, and the agent idle-exits after 60 seconds of no clients (`Apps/macOS/Agent/main.swift`), so the reset happens constantly.
- The phone app holds an optimistic `requestedRouting` plus the polled `routeState` (`Apps/iOS/Services/RelayController.swift`). On a control reconnect the phone extension clears its mirror and the agent never re-pushes.
- The Mac extension's `RouteGate` holds the routes actually installed.

The switch follows `routeState == .installed`, so a link blip flips the switch off even though the user never touched it.

## Chokepoint sweep (verified across the whole repo)

- Intent writers today: exactly two, the agent's `setRoutingEnabled` and the phone's optimistic `requestedRouting`. No others. `relay-up`, `celltunnelctl`, `handleReset`, both extensions, and the Catalyst app all funnel through the same backend call.
- Display paths all read through `RelayScreenModel` / `RelayStatus`; `relay-status` formats from `TunnelDaemonStatusSnapshot.renderedOutput`.
- The phone extension holds only `routeInstalled`. The Catalyst app polls the agent directly, so a snapshot field covers it with no extra path.
- Nothing routing-related is persisted anywhere today, so one new store creates the single durable owner with no migration.

## Model

One owner per fact:

- **User intent** lives in the agent only. `RoutingIntentStore` persists it in `UserDefaults`. Unset means **on**. Survives idle-exits, kickstarts, and reboots.
- **Live route state** lives in the Mac extension's `RouteGate` only. Unchanged.
- Routes install when intent is on AND a phone link is up. The existing reconcile logic does this; it now reads the persisted intent.

The switch shows intent. The status word ("Relay on" / "Passthrough") shows live state. They are separate facts and can differ; that is correct, not drift.

## Decisions (locked)

- The switch represents user intent, not live route state.
- Intent defaults to on; the first launch routes without a tap.
- `reset-mac` clears the preference, restoring the default-on factory state.
- No UI changes: same single switch, same status word.

## Changes

1. New `Apps/macOS/Agent/RoutingIntentStore.swift`: `load()` returns true when the key is unset, `save(_:)`, `clear()`.
2. `AgentTunnelController`: init loads from the store; `setRoutingEnabled` saves on every change; `handleReset` clears.
3. `TunnelDaemonStatusSnapshot` gains `routingIntentEnabled: Bool?` and `agentLinks` (interface, class, carrying flag per adopted link). Plain Codable, nil-safe for old payloads. The agent fills both in `augmented(...)`; the relay bridge mirrors its link set into a `Mutex` on every change, the same pattern as `linkInfo`.
4. New `routingIntent` control message (same shape as `RouteState`). The agent sends it on every intent change and on every control connection becoming ready, and re-sends `routeState` at the same hook, closing the reconnect resync gap.
5. Phone extension: `RelayRuntime` mirrors the intent next to `routeInstalled`; `PhoneControlClient` handles the new case; the phone's snapshot carries it.
6. `RelayController`: `displayedRouting` reads `routingIntentEnabled`, falling back to `routeState` when nil (old agent). The pending window stays for tap responsiveness and reconciles against intent.
7. `relay-status` becomes the one full state dump (new `Tools/CellTunnelDev/RelayState.swift`): intent (persisted + live), routes (reported + kernel count from the route table), every adopted link with class and carrying/warm, control link + peer + discovery, tunnel state + addresses, counters, and a final verdict line: `drift=none` or each mismatched pair named with exit 1. Existing `key=value` lines stay unchanged.

## Behavior matrix

| # | Scenario | Switch | Routes | Status word |
|---|---|---|---|---|
| 1 | Fresh install, link up | on (default) | installed | Relay on |
| 2 | Agent restart, intent on | stays on | reinstall on link | Relay on |
| 3 | Phone app relaunch | on at handshake | unchanged | Relay on |
| 4 | User flips off | off, saved | withdrawn | Passthrough |
| 5 | Agent restart after off | stays off | none | Passthrough |
| 6 | User flips on | on | installed | Relay on |
| 7 | Link blip under 3s | stays on | kept | Relay on |
| 8 | Link down past grace | stays on | withdrawn | Passthrough |
| 9 | Link returns | on | auto reinstall | Relay on |
| 10 | Old phone app, nil field | falls back to routeState | unchanged | unchanged |
| 11 | Agent idle-exit, relaunch | stays on (persisted) | reinstall on link | Relay on |
| 12 | Control reconnect | re-synced at handshake | re-synced | correct |
| 13 | reset-mac | back to on | none until next start | per state |
| 14 | Catalyst app | mirrors same field | same | same |

## Tests

- `RoutingIntentStore`: unset key reads true; round-trip; `clear()` restores default. Scratch `UserDefaults` suite.
- Snapshot: new fields encode/decode; an old payload without them decodes nil-safe.
- `make lint` and `swift Tools/cell-tunnel-dev.swift test` green.

## Live verification

1. Fresh start: switch on untouched, routes installed, `relay-status` full dump with `drift=none`.
2. Agent kickstart: switch stays on, routes reinstall.
3. Flip off, kickstart: stays off.
4. Flip on, link down past grace: Passthrough status, switch stays on, reported as separate facts.
5. Phone app relaunch: switch correct before the first poll.
6. Past the 60s idle window: intent survives.
7. `reset-mac`: back to default on.

## Files

- `Apps/macOS/Agent/RoutingIntentStore.swift` (new)
- `Apps/macOS/Agent/AgentTunnelController.swift`, `AgentTunnelController+Control.swift`, `AgentControlListener.swift`, `AgentRelayBridge+Links.swift`
- `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, `RelayControlMessage.swift`
- `Sources/CellTunnelRelay/PhoneControlClient.swift`, `RelayRuntime.swift`
- `Apps/iOS/Services/RelayController.swift`
- `Tools/CellTunnelDev/RelayState.swift` (new), `Tools/CellTunnelDev/RelayControl.swift`
- `Tests/CellTunnelCoreTests/` additions

# Daemon Owns the System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac agent a real daemon that starts at login, advertises on its own, and remembers the user's routing choice, so an iPhone can find the Mac without the app being open.

**Architecture:** The agent gains two launchd keys so launchd loads it at login and restarts it if it stops. Its startup path starts the control listener directly rather than waiting for a client request. The routing intent moves from a plain in-memory property to an app-group defaults store modelled on the existing `EgressSelectionStore`, and the agent restores it at boot.

**Tech Stack:** Swift 6, Swift Testing (`@Test` / `#expect`), SwiftPM for `Sources/CellTunnelCore` and `Tests/CellTunnelCoreTests`, Tuist for the app targets, launchd via `SMAppService`.

## Global Constraints

- The app group identifier is `group.io.goodkind.CellTunnel`, available in Swift as `cellTunnelAppGroupIdentifier` from `CellTunnelCore`. Never hardcode the literal in Swift.
- The mach service name is `io.goodkind.celltunnel-agent`, available as `agentMachServiceName`. Never hardcode it.
- Defaults keys in this codebase are dotted reverse-DNS strings prefixed `io.goodkind.celltunnel.`, for example `io.goodkind.celltunnel.selectedEgressDeviceID`.
- A new store in `Sources/CellTunnelCore` is `public`, is an `enum` with `static` members, and takes an injectable `UserDefaults?` parameter on every entry point defaulting to `nil`, matching `Sources/CellTunnelCore/EgressSelectionStore.swift`.
- Tests live in `Tests/CellTunnelCoreTests` and use Swift Testing, not XCTest. Follow `Tests/CellTunnelCoreTests/StickyEgressSelectionTests.swift`, which tests a store against a throwaway `UserDefaults` suite.
- Build and gate with the repo's dev tool, not `swift build`:
  `SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic swift Tools/cell-tunnel-dev.swift build mac Debug`
- Run package tests with `swift test --filter <SuiteName>` from the repo root.
- Every gate must pass: `lint-swiftlint`, `lint-format`, `lint-complexity`, `lint-deadcode`, `swiftcheck-extra`, `audit`. A new file in `Sources/` must be reachable from a SwiftPM target or `lint-deadcode` fails it.
- Enum cases must be declared in alphabetical order; `lint-swiftlint` enforces it.
- An access modifier goes on each member, not on the `extension`; `lint-format` and `lint-swiftlint` disagree otherwise. Prefer declaring members inside the type.
- Vertical whitespace is limited to a single empty line.

---

### Task 1: Persist the routing intent

The agent forgets whether the user wanted routing on. `AgentTunnelController.swift:110` declares `var routingEnabled = false` with a comment stating it is in-memory with no persistence, so every agent start resets it to off. This task adds the store and its tests only. Task 3 wires the agent to it.

**Files:**
- Create: `Sources/CellTunnelCore/RoutingIntentStore.swift`
- Test: `Tests/CellTunnelCoreTests/RoutingIntentStoreTests.swift`

**Interfaces:**
- Consumes: `cellTunnelAppGroupIdentifier` from `Sources/CellTunnelCore/Generated/Config.generated.swift`.
- Produces: `RoutingIntentStore.routingEnabled(from:) -> Bool?`, `RoutingIntentStore.setRoutingEnabled(_:to:)`, `RoutingIntentStore.clear(in:)`. Task 3 calls all three.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/RoutingIntentStoreTests.swift`:

```swift
//
//  RoutingIntentStoreTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import CellTunnelCore

@Suite("Routing intent store")
struct RoutingIntentStoreTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "io.goodkind.celltunnel.tests.routingintent.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("could not create a throwaway defaults suite")
    }
    return defaults
  }

  /// A machine that has never chosen reports no choice, so the agent can tell
  /// "never asked" apart from "asked for off".
  @Test("an unset intent reads as no choice")
  func unsetReadsAsNoChoice() {
    let defaults = makeDefaults()
    #expect(RoutingIntentStore.routingEnabled(from: defaults) == nil)
  }

  @Test("an intent to route survives being written and read back")
  func storesEnabled() {
    let defaults = makeDefaults()
    RoutingIntentStore.setRoutingEnabled(true, to: defaults)
    #expect(RoutingIntentStore.routingEnabled(from: defaults) == true)
  }

  /// Off must be stored rather than treated as absent, or a user who turns
  /// routing off gets it turned back on at the next agent start.
  @Test("an intent not to route is stored, not treated as absent")
  func storesDisabled() {
    let defaults = makeDefaults()
    RoutingIntentStore.setRoutingEnabled(false, to: defaults)
    #expect(RoutingIntentStore.routingEnabled(from: defaults) == false)
  }

  @Test("clearing returns the store to no choice")
  func clearRemovesTheChoice() {
    let defaults = makeDefaults()
    RoutingIntentStore.setRoutingEnabled(true, to: defaults)
    RoutingIntentStore.clear(in: defaults)
    #expect(RoutingIntentStore.routingEnabled(from: defaults) == nil)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter RoutingIntentStoreTests`
Expected: FAIL to compile, `cannot find 'RoutingIntentStore' in scope`.

- [ ] **Step 3: Write the store**

Create `Sources/CellTunnelCore/RoutingIntentStore.swift`:

```swift
//
//  RoutingIntentStore.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Constants

private let routingIntentEnabledKey = "io.goodkind.celltunnel.routingIntentEnabled"

// MARK: - RoutingIntentStore

/// Remembers whether the user wants traffic routed through the tunnel.
///
/// The agent restarts for reasons the user did not ask for, such as a logout or
/// an upgrade. Without a record of the choice, every restart silently turns
/// routing off and the user has to notice and turn it back on.
///
/// The absence of a value is meaningful and is not the same as off: it means the
/// user has never chosen, which lets the agent leave routing alone rather than
/// assert a choice the user never made.
public enum RoutingIntentStore {
  private static func resolvedDefaults(_ defaults: UserDefaults?) -> UserDefaults {
    defaults ?? UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
  }

  /// The user's choice, or nil when they have never made one.
  public static func routingEnabled(from defaults: UserDefaults? = nil) -> Bool? {
    let store = resolvedDefaults(defaults)
    guard store.object(forKey: routingIntentEnabledKey) != nil else {
      return nil
    }
    return store.bool(forKey: routingIntentEnabledKey)
  }

  /// Records the user's choice, including a choice not to route.
  public static func setRoutingEnabled(_ enabled: Bool, to defaults: UserDefaults? = nil) {
    resolvedDefaults(defaults).set(enabled, forKey: routingIntentEnabledKey)
  }

  /// Forgets the choice, so the agent treats the machine as never having chosen.
  public static func clear(in defaults: UserDefaults? = nil) {
    resolvedDefaults(defaults).removeObject(forKey: routingIntentEnabledKey)
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter RoutingIntentStoreTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Run the full gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/CellTunnelCore/RoutingIntentStore.swift Tests/CellTunnelCoreTests/RoutingIntentStoreTests.swift
git commit -S -m "Remember whether the user wants traffic routed" \
  -m "The choice lived only in agent memory, so every restart turned routing off without the user asking. An absent value stays distinct from off, so a machine that has never chosen is left alone." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 2: Load the agent at login and keep it loaded

The launch agent plist declares a mach service but sets neither `RunAtLoad` nor `KeepAlive`, so launchd starts the agent only when a client dials the service and never restarts it. After a reboot with the app closed, no agent exists.

**Files:**
- Modify: `Templates/Plists/agent-launchd.plist.template`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a generated plist at `Generated/CellTunnelAgent/agent-launchd.plist` carrying `RunAtLoad` and `KeepAlive`. Task 3 relies on the agent being resident.

- [ ] **Step 1: Add the two keys**

In `Templates/Plists/agent-launchd.plist.template`, insert these keys immediately after the `MachServices` dict closes and before `AssociatedBundleIdentifiers`:

```xml
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
```

Keep the existing keys and their order otherwise unchanged.

- [ ] **Step 2: Regenerate and confirm the rendered plist**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Then:
```bash
plutil -p Generated/CellTunnelAgent/agent-launchd.plist
```
Expected: the printed dictionary contains `"RunAtLoad" => 1` and `"KeepAlive" => 1`, alongside the existing `Label`, `BundleProgram`, `MachServices`, `AssociatedBundleIdentifiers`, and `ProcessType` keys.

- [ ] **Step 3: Confirm the built bundle carries it**

Run:
```bash
plutil -p Products/Debug/CellTunnelAgent.app/Contents/Library/LaunchAgents/agent-launchd.plist
```
Expected: same two keys present.

- [ ] **Step 4: Commit**

```bash
git add Templates/Plists/agent-launchd.plist.template Generated/CellTunnelAgent/agent-launchd.plist
git commit -S -m "Load the agent at login and restart it if it stops" \
  -m "launchd started the agent only when a client dialled its service, so after a reboot with no app open nothing advertised and an iPhone browsing for the Mac found nothing." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 3: Advertise and restore the routing choice at startup

`AgentRuntime.start()` in `Apps/macOS/Agent/main.swift:40-52` registers the launch agent and starts the XPC listener, then stops. It never calls `ensureControlListenerStarted()`, which is the only thing that publishes the Bonjour record the iPhone browses for. Its four callers are all client-request handlers, so a launchd-started agent is silent until a client asks it to pair.

**Files:**
- Modify: `Apps/macOS/Agent/main.swift:40-52`
- Modify: `Apps/macOS/Agent/AgentTunnelController.swift:103-110`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Control.swift:334, 344, 352, 372, 439`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Requests.swift:321`

**Interfaces:**
- Consumes: `RoutingIntentStore.routingEnabled(from:)`, `RoutingIntentStore.setRoutingEnabled(_:to:)`, and `RoutingIntentStore.clear(in:)` from Task 1. A resident agent from Task 2.
- Produces: `AgentTunnelController.restoreStartupState()`, an `async` method taking no arguments and returning nothing, called once from the composition root.

- [ ] **Step 1: Make every routing-intent write persist**

In `AgentTunnelController.swift`, replace the stored property and its comment at lines 103-110 with a computed property backed by the store, so no write site can forget to persist:

```swift
  /// Whether the user wants traffic routed through the tunnel.
  ///
  /// Backed by `RoutingIntentStore`, so the choice survives an agent restart the
  /// user did not ask for. Reading before any choice has been made yields false,
  /// which is the safe default: the agent asserts nothing the user did not.
  var routingEnabled: Bool {
    get { RoutingIntentStore.routingEnabled() ?? false }
    set { RoutingIntentStore.setRoutingEnabled(newValue) }
  }
```

Leave every existing assignment at `+Control.swift:334, 344, 352, 372, 439` and `+Requests.swift:321` unchanged; they now persist through the setter.

- [ ] **Step 2: Clear the choice on reset**

In `AgentTunnelController+Requests.swift`, in `handleReset()`, immediately after the existing `routingEnabled = false` at line 321, add:

```swift
    RoutingIntentStore.clear()
```

A reset returns the machine to never-chosen rather than chose-off.

- [ ] **Step 3: Add the startup restore**

Add to `AgentTunnelController+Control.swift`, inside the existing `extension AgentTunnelController`:

```swift
  /// Brings the agent to a usable state at launch without waiting for a client.
  ///
  /// The iPhone finds the Mac by browsing for the control listener's Bonjour
  /// record, and nothing else publishes it, so an agent that waits for a request
  /// is invisible to the one participant that cannot send one.
  ///
  /// Routing is not started here. The user's remembered choice is honoured only
  /// once a phone connects, because routing without a relay would install routes
  /// to nothing.
  func restoreStartupState() async {
    do {
      try await ensureControlListenerStarted()
    } catch {
      logger.error(
        """
        agent startup listener failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=await-client-request
        """
      )
    }
  }
```

- [ ] **Step 4: Call it from the composition root**

In `Apps/macOS/Agent/main.swift`, immediately after `agentRuntime.start()` at line 167 and before the existing `assertRunningConfigMatchesLibrary` task at line 171, add:

```swift
  // Advertise without waiting for a client. The iPhone browses for the control
  // listener's record and cannot dial the mach service, so an agent that starts
  // silent is unreachable by the device it exists to serve.
  Task { await controller.restoreStartupState() }
```

- [ ] **Step 5: Build and gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

- [ ] **Step 6: Verify the agent advertises with no client**

Run:
```bash
launchctl bootout gui/501/io.goodkind.celltunnel-agent 2>/dev/null
cp -R Products/Debug/CellTunnelAgent.app /tmp/agent-check.app
open -a /tmp/agent-check.app
sleep 8
dns-sd -t 10 -B _cellrelaycontrol._tcp local > /tmp/advertise-check.txt 2>&1
grep -c 'Add' /tmp/advertise-check.txt
```
Expected: at least one `Add` line, meaning the record is published without any client having sent a request. `dns-sd` without `-t` never terminates over a non-interactive session, so the timeout is required.

- [ ] **Step 7: Verify the routing choice survives a restart**

Run:
```bash
Products/celltunnelctl status 2>&1 | grep routing_intent
launchctl kickstart -k gui/501/io.goodkind.celltunnel-agent
sleep 5
Products/celltunnelctl status 2>&1 | grep routing_intent
```
Expected: the same `routing_intent` value before and after the restart.

- [ ] **Step 8: Commit**

```bash
git add Apps/macOS/Agent/main.swift Apps/macOS/Agent/AgentTunnelController.swift Apps/macOS/Agent/AgentTunnelController+Control.swift Apps/macOS/Agent/AgentTunnelController+Requests.swift
git commit -S -m "Advertise at startup and keep the routing choice across restarts" \
  -m "Only a client request published the Bonjour record the iPhone browses for, and the iPhone cannot send one, so a freshly started agent was unreachable by the device it serves." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

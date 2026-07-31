# Logic Moves Into The Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the decisions that currently live in the app into shared code and the daemon, so the app only renders and `celltunnelctl` can show the same state.

**Architecture:** The daemon publishes which situation the machine is in, not the words for it. Each state machine becomes a pure function in `Sources/CellTunnelCore` over the status snapshot, the daemon runs it and puts the result on the wire, and each client maps that result to its own text. Wording and translation stay in the app; the decision does not. Twelve decisions currently held only by the app either move to the daemon or become one shared function both sides call.

**Tech Stack:** Swift 6, Swift Testing (`@Test` / `#expect`), SwiftPM for `Sources/CellTunnelCore` and `Tests/CellTunnelCoreTests`, Tuist for the app targets.

## Global Constraints

- Tests live in `Tests/CellTunnelCoreTests` and use Swift Testing (`import Testing`, `@Test`, `#expect`), never XCTest.
- A new file in `Sources/` must be reachable from a SwiftPM target or the `lint-deadcode` gate fails it. `Sources/CellTunnelCore` is already a target, so a new file there is reachable; a symbol nothing calls is not.
- Enum cases must be declared in alphabetical order; `lint-swiftlint` enforces it.
- SwiftLint rejects an optional `Bool` return, so a tri-state is an enum, never `Bool?`. There is no inline disable comment available: the repo makes any `swiftlint:disable` a hard error.
- An access modifier goes on each member, never on an `extension`.
- Vertical whitespace is limited to a single empty line.
- No em dashes anywhere, in code, comments, or commit messages.
- Comments explain why, never what. A doc comment on a new type explains the situation that makes the type necessary.
- The gate command, run from the repo root:
  `SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic swift Tools/cell-tunnel-dev.swift build mac Debug`
- Package tests: `swift test --filter <SuiteName>` from the repo root.
- The app group identifier is `cellTunnelAppGroupIdentifier` from `CellTunnelCore`. Never hardcode the literal.

---

### Task 1: Delete the app's second copy of peer auto-selection

The iPhone dials a Mac twice, by two different rules. The tunnel extension dials only when exactly one Mac is discovered and deliberately dials nothing when several are visible, because only the user can say which Mac carries their traffic. The app dials `discoveredPeers.first` whenever nothing is selected, regardless of count, and it runs only while the app is foregrounded. In a house with two Macs the app therefore overrides the extension's abstention and connects to whichever one Bonjour happened to list first.

**Files:**
- Create: `Sources/CellTunnelCore/RelayDialTarget.swift`
- Modify: `Sources/CellTunnelRelay/RelayRuntime.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Modify: `Apps/iOS/Services/RelayControlBackend.swift`
- Modify: `Apps/iOS/Services/PhoneRelayBackend.swift`
- Modify: `Apps/iOS/Services/SimulatorRelayBackend.swift`
- Test: `Tests/CellTunnelCoreTests/RelayDialTargetTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `public func relayDialTarget(selectedServiceID: String?, services: [TunnelRelayService]) -> String?` in `CellTunnelCore`. Later tasks do not depend on it.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/RelayDialTargetTests.swift`:

```swift
//
//  RelayDialTargetTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - RelayDialTargetTests

/// Covers which discovered Mac the iPhone dials. The abstention with several Macs
/// visible is the point of the rule, so it is the case that must not regress.
struct RelayDialTargetTests {
  private func service(id: String) -> TunnelRelayService {
    TunnelRelayService(
      id: id,
      serviceName: id,
      serviceType: "_cellrelaycontrol._tcp",
      domain: "local",
      interfaceIndex: 0,
      hostName: "\(id).local",
      endpoints: [],
      preferredEndpoint: nil,
      isSelected: false
    )
  }

  @Test func dialsNothingWhenNothingDiscovered() {
    #expect(relayDialTarget(selectedServiceID: nil, services: []) == nil)
  }

  @Test func dialsTheLoneDiscoveredMac() {
    let target = relayDialTarget(selectedServiceID: nil, services: [service(id: "a")])

    #expect(target == "a")
  }

  @Test func abstainsWhenSeveralMacsAreVisible() {
    // Two Macs and no standing selection: only the user can say which one carries
    // their traffic, so nothing dials.
    let target = relayDialTarget(
      selectedServiceID: nil,
      services: [service(id: "a"), service(id: "b")]
    )

    #expect(target == nil)
  }

  @Test func keepsTheStandingSelectionWhileItIsStillVisible() {
    let target = relayDialTarget(
      selectedServiceID: "b",
      services: [service(id: "a"), service(id: "b")]
    )

    #expect(target == "b")
  }

  @Test func abstainsWhenTheStandingSelectionDisappearsAmongSeveral() {
    // The chosen Mac went away and two others remain: falling back to the first
    // listed is what the app's copy did, and it is what must not happen.
    let target = relayDialTarget(
      selectedServiceID: "gone",
      services: [service(id: "a"), service(id: "b")]
    )

    #expect(target == nil)
  }
}
```

Run `swift test --filter RelayDialTargetTests`. Expected failure: the test target does not compile, with `error: cannot find 'relayDialTarget' in scope` at every call site.

- [ ] **Step 2: Add the shared rule**

Create `Sources/CellTunnelCore/RelayDialTarget.swift`:

```swift
//
//  RelayDialTarget.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

// MARK: - relayDialTarget

/// Picks which discovered Mac the iPhone dials.
///
/// This decision existed twice with different rules, and the app's copy dialled the
/// first listed Mac regardless of how many were visible, so a house with two Macs
/// connected to whichever one Bonjour happened to list first. Abstaining when several
/// are visible is deliberate rather than an omission: only the user can say which Mac
/// carries their traffic. Keeping the rule here, where it is tested, is what stops a
/// second copy appearing again.
public func relayDialTarget(
  selectedServiceID: String?,
  services: [TunnelRelayService]
) -> String? {
  if let selectedServiceID, services.contains(where: { $0.id == selectedServiceID }) {
    return selectedServiceID
  }
  if services.count == 1 {
    return services.first?.id
  }
  return nil
}
```

Run `swift test --filter RelayDialTargetTests`. Expected: all five tests pass.

- [ ] **Step 3: Point the extension at the shared rule**

In `Sources/CellTunnelRelay/RelayRuntime.swift`, inside `applyDiscoveredServices(_:)`, replace the call

```swift
      let resolved = Self.dialTarget(selected: state.selectedServiceID, services: services)
```

with

```swift
      let resolved = relayDialTarget(
        selectedServiceID: state.selectedServiceID, services: services)
```

Then delete the whole private helper that follows, including its comment block:

```swift
  // Resolves which discovered service to dial: the standing selection when it is
  // still present, otherwise the lone discovered peer, otherwise none.
  private static func dialTarget(
    selected: String?,
    services: [TunnelRelayService]
  ) -> String? {
    if let selected, services.contains(where: { $0.id == selected }) {
      return selected
    }
    if services.count == 1 {
      return services.first?.id
    }
    return nil
  }
```

- [ ] **Step 4: Delete the app's copy**

In `Apps/iOS/Services/RelayController.swift`, delete the stored guard and its comment:

```swift
  // Guards the iPhone auto-dial so the first discovered Mac is selected once rather
  // than re-requested every poll while the selection lands.
  private var autoSelectInFlight = false
```

Delete the call inside `apply(_:)`:

```swift
    maybeAutoSelectPeer()
```

Delete the whole method and its comment from the `Peer selection` extension:

```swift
  // Auto-dials the first discovered peer when the backend opts in (the iPhone) and
  // none is selected, so the iPhone connects to its Mac with no picker. The guard
  // clears once the request returns, and the next snapshot's selected id stops it
  // from firing again.
  func maybeAutoSelectPeer() {
    guard backend.autoSelectsDiscoveredPeer, !autoSelectInFlight, selectedPeerID == nil,
      let first = discoveredPeers.first
    else {
      return
    }
    autoSelectInFlight = true
    logger.notice("relay controller auto-dialing discovered peer")
    Task { @MainActor [weak self] in
      await self?.backend.selectPeer(id: first.id)
      self?.autoSelectInFlight = false
    }
  }
```

- [ ] **Step 5: Delete the backend opt-in the deleted code was the only reader of**

In `Apps/iOS/Services/RelayControlBackend.swift`, delete the protocol requirement at line 35 with its doc comment, and delete the default implementation at lines 44 to 46:

```swift
  var autoSelectsDiscoveredPeer: Bool {
    false
  }
```

In `Apps/iOS/Services/PhoneRelayBackend.swift`, delete the override at line 262. In `Apps/iOS/Services/SimulatorRelayBackend.swift`, delete the override at line 69. Leave `usesEgressRoster` alone in all three: the status screen still reads it.

- [ ] **Step 6: Build and gate**

```bash
swift test --filter RelayDialTargetTests
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```

Expected: tests pass, every gate `ok`, exit 0. `lint-deadcode` is the gate that catches a leftover `autoSelectsDiscoveredPeer` conformance.

- [ ] **Step 7: Commit**

```bash
git add Sources/CellTunnelCore/RelayDialTarget.swift \
  Tests/CellTunnelCoreTests/RelayDialTargetTests.swift \
  Sources/CellTunnelRelay/RelayRuntime.swift \
  Apps/iOS/Services/RelayController.swift \
  Apps/iOS/Services/RelayControlBackend.swift \
  Apps/iOS/Services/PhoneRelayBackend.swift \
  Apps/iOS/Services/SimulatorRelayBackend.swift
git commit -S -m "Decide which Mac to dial in one place" \
  -m "The app dialled the first discovered Mac regardless of how many were visible, overriding the extension's deliberate abstention, so a house with two Macs connected to whichever one Bonjour listed first and only while the app was open." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 2: Publish one rule for whether routing may start

The app and the agent decide "can routing start" by different rules. The app checks `activeConfigID != nil` on the Mac and shows a live switch when that holds. The agent additionally requires the config text to resolve out of the store and a selected peer connection, and rejects with `relaySelectionRequired` when there is none. The user therefore sees a live switch, flips it, and the agent refuses. The fix is one function whose answer the agent computes and publishes, so no client re-derives it.

**Files:**
- Create: `Sources/CellTunnelCore/RoutingStartReadiness.swift`
- Modify: `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`
- Modify: `Sources/CellTunnelCore/RouteControl.swift`
- Modify: `Sources/CellTunnelRelay/RelayRuntime.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Control.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Requests.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Modify: `Apps/iOS/Views/RelayScreenModel.swift`
- Modify: `Apps/iOS/Views/MacStatusScreen.swift`
- Modify: `Apps/iOS/Views/RelayStatusScreen.swift`
- Test: `Tests/CellTunnelCoreTests/RoutingStartReadinessTests.swift`
- Test: `Tests/CellTunnelCoreTests/RouteControlTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `public enum RoutingStartReadiness: String, Codable, Equatable, Sendable` with cases `noActiveConfig`, `noSelectedPeer`, `ready`, and members `rejectionErrorCode: TunnelControlErrorCode?`, `rejectionMessage: String?`, `canProceed: Bool`.
  - `public func routingStartReadiness(hasActiveConfig: Bool, hasSelectedPeer: Bool) -> RoutingStartReadiness`
  - `public let noSelectedPeerConnectionMessage: String`
  - `TunnelDaemonStatusSnapshot.routingStartReadiness: RoutingStartReadiness?`, last initializer parameter, defaulting to `nil`.
  - `RouteControlPresentation.disabled(reason: RoutingStartReadiness)`, replacing `disabled(hint: String)`. `RouteControl.chooseConfigHint` is deleted.
  - `RouteControl.init(isPeerConnected:isRoutingEngaged:readiness:isRouting:requestedRouting:isRequestPending:)`, where `readiness` replaces `hasActiveConfig`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/RoutingStartReadinessTests.swift`:

```swift
//
//  RoutingStartReadinessTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - RoutingStartReadinessTests

/// Covers the one rule for whether routing may start, the rule the agent enforces and
/// the app renders the switch from. The missing-peer case is the one the app used to
/// miss, which is what produced a live switch the agent then rejected.
struct RoutingStartReadinessTests {
  @Test func readyWithActiveConfigAndSelectedPeer() {
    let readiness = routingStartReadiness(hasActiveConfig: true, hasSelectedPeer: true)

    #expect(readiness == .ready)
    #expect(readiness.canProceed)
    #expect(readiness.rejectionErrorCode == nil)
    #expect(readiness.rejectionMessage == nil)
  }

  @Test func noActiveConfigRejectsWithConfigSelectionRequired() {
    let readiness = routingStartReadiness(hasActiveConfig: false, hasSelectedPeer: true)

    #expect(readiness == .noActiveConfig)
    #expect(readiness.canProceed == false)
    #expect(readiness.rejectionErrorCode == .configSelectionRequired)
    #expect(readiness.rejectionMessage == noActiveConfigSelectedMessage)
  }

  @Test func noSelectedPeerRejectsWithRelaySelectionRequired() {
    // The case the app did not check. Its switch was live here and the agent refused.
    let readiness = routingStartReadiness(hasActiveConfig: true, hasSelectedPeer: false)

    #expect(readiness == .noSelectedPeer)
    #expect(readiness.canProceed == false)
    #expect(readiness.rejectionErrorCode == .relaySelectionRequired)
    #expect(readiness.rejectionMessage == noSelectedPeerConnectionMessage)
  }

  @Test func missingConfigOutranksMissingPeer() {
    // With neither present the user must pick a config first, so that is the reason
    // shown rather than a peer prompt they cannot act on yet.
    let readiness = routingStartReadiness(hasActiveConfig: false, hasSelectedPeer: false)

    #expect(readiness == .noActiveConfig)
  }

  @Test func travelsOnTheWire() {
    let snapshot = TunnelDaemonStatusSnapshot(routingStartReadiness: .noSelectedPeer)
    let encoded = try? JSONEncoder().encode(snapshot)
    let decoded = encoded.flatMap {
      try? JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: $0)
    }

    #expect(decoded?.routingStartReadiness == .noSelectedPeer)
  }

  @Test func absentFromAnOlderProducer() {
    // A producer that predates the field sends nothing rather than a wrong answer.
    #expect(TunnelDaemonStatusSnapshot().routingStartReadiness == nil)
  }
}
```

Add `import Foundation` at the top alongside the other imports, since the wire test uses `JSONEncoder`.

Run `swift test --filter RoutingStartReadinessTests`. Expected failure: `error: cannot find 'routingStartReadiness' in scope` and `error: extra argument 'routingStartReadiness' in call`.

- [ ] **Step 2: Add the shared rule**

Create `Sources/CellTunnelCore/RoutingStartReadiness.swift`:

```swift
//
//  RoutingStartReadiness.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

// MARK: - RoutingStartReadiness

/// Whether routing may start, and when it may not, which situation blocks it.
///
/// This was decided twice with different rules. The app checked only that a config was
/// active, so it drew a live switch; the agent additionally required the config text to
/// resolve and a selected peer connection, so it refused the request the switch sent.
/// The daemon publishes the value from this one rule and no client re-derives it, which
/// is what keeps a control from offering an action the daemon will reject.
///
/// A tri-state rather than a `Bool` pair, because the blocked cases name different
/// situations the client explains differently.
public enum RoutingStartReadiness: String, Codable, Equatable, Sendable {
  case noActiveConfig = "no-active-config"
  case noSelectedPeer = "no-selected-peer"
  case ready

  /// The error code a rejection returns, or `nil` when routing may proceed. Ties the
  /// request path's failure code to the same value the client rendered the control from.
  public var rejectionErrorCode: TunnelControlErrorCode? {
    switch self {
    case .noActiveConfig:
      return .configSelectionRequired
    case .noSelectedPeer:
      return .relaySelectionRequired
    case .ready:
      return nil
    }
  }

  /// The message a rejection returns, or `nil` when routing may proceed.
  public var rejectionMessage: String? {
    switch self {
    case .noActiveConfig:
      return noActiveConfigSelectedMessage
    case .noSelectedPeer:
      return noSelectedPeerConnectionMessage
    case .ready:
      return nil
    }
  }

  /// Whether routing may proceed past the check to mark intent and start.
  public var canProceed: Bool {
    rejectionErrorCode == nil
  }
}

// MARK: - Shared message

/// The user-facing message for a no-selected-peer rejection, shared by the request
/// path's failure response and any client that phrases the blocked control, so the two
/// cannot drift.
public let noSelectedPeerConnectionMessage = "no selected peer connection"

// MARK: - Decision

/// Classifies whether routing may start. A missing config outranks a missing peer,
/// because choosing a config is the step the user can take first. The caller resolves
/// both facts before calling, so this stays pure and has no store or listener access.
public func routingStartReadiness(
  hasActiveConfig: Bool,
  hasSelectedPeer: Bool
) -> RoutingStartReadiness {
  if !hasActiveConfig {
    return .noActiveConfig
  }
  if !hasSelectedPeer {
    return .noSelectedPeer
  }
  return .ready
}
```

- [ ] **Step 3: Put the answer on the wire**

In `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, add the stored property immediately after `vpnProfileState`:

```swift
  /// Whether routing may start right now, as the producer itself decides it, so no
  /// client draws a control the producer would refuse. `nil` from a producer that
  /// predates the field.
  public var routingStartReadiness: RoutingStartReadiness?
```

Add `routingStartReadiness: RoutingStartReadiness? = nil` as the last parameter of `init`, and `self.routingStartReadiness = routingStartReadiness` as the last assignment in its body.

In `renderedOutput`, immediately after the `vpnProfileState` block, add:

```swift
    if let routingStartReadiness {
      lines.append("routing_readiness=\(routingStartReadiness.rawValue)")
    }
```

Run `swift test --filter RoutingStartReadinessTests`. Expected: all six tests pass.

- [ ] **Step 4: Make the switch read the published reason**

In `Sources/CellTunnelCore/RouteControl.swift`, replace the presentation enum and the hint constant. The disabled case now carries the situation rather than a phrase, so the client owns the wording:

```swift
/// How the single Route traffic switch presents itself, the one value the status
/// screens read to decide whether the switch shows and whether it is live. `hidden`
/// when no peer can carry traffic, `disabled` when the producer says routing cannot
/// start and the reason names what is missing, `enabled` when the switch is a live
/// control. The reason is a situation rather than a phrase, because each client writes
/// its own words for it.
public enum RouteControlPresentation: Equatable, Sendable {
  case disabled(reason: RoutingStartReadiness)
  case enabled
  case hidden
}
```

Delete the `chooseConfigHint` declaration:

```swift
  /// The hint shown on the disabled switch when a peer is connected but no config is
  /// active, naming the choice the user must make before routing can start.
  public static let chooseConfigHint = "Choose a config"
```

Replace the `hasActiveConfig` parameter with `readiness`, and the presentation branch that used it:

```swift
  public init(
    isPeerConnected: Bool,
    isRoutingEngaged: Bool,
    readiness: RoutingStartReadiness,
    isRouting: Bool,
    requestedRouting: Bool,
    isRequestPending: Bool
  ) {
    let resolvedPresentation: RouteControlPresentation
    if !isPeerConnected {
      resolvedPresentation = .hidden
    } else if !readiness.canProceed {
      resolvedPresentation = .disabled(reason: readiness)
    } else {
      resolvedPresentation = .enabled
    }
    presentation = resolvedPresentation
```

Leave the rest of the initializer body unchanged.

- [ ] **Step 5: Update the switch tests**

In `Tests/CellTunnelCoreTests/RouteControlTests.swift`, replace every `hasActiveConfig: true` argument with `readiness: .ready` and every `hasActiveConfig: false` with `readiness: .noActiveConfig`, keeping the argument in the same position. Replace both expectations of the form

```swift
    #expect(control.presentation == .disabled(hint: RouteControl.chooseConfigHint))
```

with

```swift
    #expect(control.presentation == .disabled(reason: .noActiveConfig))
```

Add one test at the end of the suite, covering the case the app used to draw as live:

```swift
  // MARK: - Blocked on the peer

  @Test func disabledWhenPeerConnectedButNoneSelected() {
    // A config is active and a peer link is up, but no peer is selected for egress, so
    // the agent would refuse a turn-on. The switch must be disabled rather than live.
    let control = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: false,
      readiness: .noSelectedPeer,
      isRouting: false,
      requestedRouting: false,
      isRequestPending: false
    )

    #expect(control.presentation == .disabled(reason: .noSelectedPeer))
    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }
```

Run `swift test --filter RouteControlTests`. Expected: every test passes.

- [ ] **Step 6: Have the agent publish its own answer**

In `Apps/macOS/Agent/AgentTunnelController+Control.swift`, inside `augmented(_:profileState:)`, replace the single line

```swift
    merged.connectedPeers = connectedPeers.withLock { $0 }
```

with

```swift
    let peers = connectedPeers.withLock { $0 }
    merged.connectedPeers = peers
    // The agent answers this itself so no client re-derives it and draws a control the
    // agent would then refuse. The config must resolve out of the store, not merely be
    // named, because an unresolvable id is what the request path rejects.
    merged.routingStartReadiness = routingStartReadiness(
      hasActiveConfig: configStore.activeID.flatMap { configStore.text(forID: $0) } != nil,
      hasSelectedPeer: peers.contains { $0.isSelected }
    )
```

- [ ] **Step 7: Have the agent's request path enforce the same value**

In `Apps/macOS/Agent/AgentTunnelController+Requests.swift`, replace the body of the `if enabled` branch in `handleSetRoutingEnabled(_:)`, from `let hasConfig` through the closing brace of the peer check, with:

```swift
      // Start the pairing listener before the readiness check, matching startTunnel and
      // startRelay. On a fresh agent this brings the listener up so the iPhone can dial
      // in; without it the peer check fails forever and the listener never starts.
      // Idempotent: a no-op when the listener is already running.
      do {
        try await ensureControlListenerStarted()
      } catch {
        logger.error(
          """
          setRoutingEnabled ensure listener failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=return-failure-response
          """
        )
        return failure(from: error)
      }
      // The same value the snapshot published, so a rejection here can only name a
      // situation the client already showed on the control.
      let readiness = routingStartReadiness(
        hasActiveConfig: configStore.activeID.flatMap { configStore.text(forID: $0) } != nil,
        hasSelectedPeer: await controlListener?.hasSelectedPeer() == true
      )
      if let rejectionErrorCode = readiness.rejectionErrorCode,
        let rejectionMessage = readiness.rejectionMessage
      {
        return failure(errorCode: rejectionErrorCode, message: rejectionMessage)
      }
```

Leave `await setRoutingEnabled(enabled)` and `return await handleStatus()` unchanged. `routingEnablePrecondition` stays where it is: it still serves the live switch path in `enableRouting()`, which has a relay-hosted fast path this request path does not.

- [ ] **Step 8: Have the iPhone's runtime publish its own answer**

In `Sources/CellTunnelRelay/RelayRuntime.swift`, inside `statusSnapshot()`, add a trailing argument to the `TunnelDaemonStatusSnapshot(...)` call, after `routingIntentEnabled: state.routingIntent`:

```swift
      routingStartReadiness: routingStartReadiness(
        hasActiveConfig: state.running,
        hasSelectedPeer: state.selectedServiceID != nil
      )
```

The iPhone holds no config library, so its config fact is whether the tunnel session is up at all, and its peer fact is whether a Mac is selected.

- [ ] **Step 9: Delete the app's copy of the rule**

In `Apps/iOS/Services/RelayController.swift`, add the field to `RelayStatusSample` immediately after `vpnProfileState`:

```swift
  /// Whether the producer says routing may start. The app never re-derives this: a
  /// second rule here is what produced a live switch the agent refused.
  var routingStartReadiness: RoutingStartReadiness
```

In `RelayStatusSample.init(snapshot:)`, add as the last assignment:

```swift
    // A producer that predates the field says nothing, and the agent's rejection is
    // then the only backstop, so an upgrade in progress behaves as it did before.
    routingStartReadiness = snapshot.routingStartReadiness ?? .ready
```

Add the observable property beside `routingIntentEnabled`:

```swift
  /// Whether the producer says routing may start, mirrored from the snapshot so the
  /// switch and the agent agree on one answer.
  var routingStartReadiness: RoutingStartReadiness = .ready
```

Assign it in `apply(_:)`, immediately after the `routingIntentEnabled` assignment:

```swift
    assign(\.routingStartReadiness, sample.routingStartReadiness)
```

Delete the computed property and its doc comment from the `Routing control` extension:

```swift
  /// Whether the current platform has an active relay configuration. Mac Catalyst
  /// reads the agent library selection, while the iPhone reads its approved VPN state.
  var hasActiveConfig: Bool {
    #if targetEnvironment(macCatalyst)
      return activeConfigID != nil
    #else
      return isTunnelInstalled
    #endif
  }
```

In `routeControl`, replace `hasActiveConfig: hasActiveConfig,` with `readiness: routingStartReadiness,`.

- [ ] **Step 10: Give the app the words for each reason**

In `Apps/iOS/Views/RelayScreenModel.swift`, add these constants beside `connectingStatusLabel`:

```swift
private let chooseConfigHint = "Choose a config"
private let choosePeerHint = "Choose a peer"
```

Add this method to the `RelayScreenModel` body, immediately after `routeControl`:

```swift
  /// The words for a blocked routing control. The daemon publishes which situation
  /// blocks it and the app writes the sentence, so wording changes never touch the
  /// rule and `celltunnelctl` phrases the same situation its own way.
  func routeBlockedHint(_ reason: RoutingStartReadiness) -> String {
    switch reason {
    case .noActiveConfig:
      return chooseConfigHint
    case .noSelectedPeer:
      return choosePeerHint
    case .ready:
      return ""
    }
  }
```

In `Apps/iOS/Views/MacStatusScreen.swift`, in `routeControlView`, replace

```swift
      case .disabled(let hint):
        HStack(spacing: routeSpinnerSpacing) {
          Text(hint)
```

with

```swift
      case .disabled(let reason):
        HStack(spacing: routeSpinnerSpacing) {
          Text(model.routeBlockedHint(reason))
```

Apply the same replacement in `Apps/iOS/Views/RelayStatusScreen.swift` at its `case .disabled(let hint):` branch, matching that file's surrounding indentation.

- [ ] **Step 11: Build and gate**

```bash
swift test --filter RoutingStartReadinessTests
swift test --filter RouteControlTests
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```

Expected: tests pass, every gate `ok`, exit 0.

- [ ] **Step 12: Verify the switch and the agent now agree**

With the agent running and a config active but no iPhone dialled in:

```bash
Products/celltunnelctl status 2>&1 | grep routing_readiness
```

Expected: `routing_readiness=no-selected-peer`, and the Mac app shows a disabled switch reading `Choose a peer` rather than a live one.

- [ ] **Step 13: Commit**

```bash
git add Sources/CellTunnelCore/RoutingStartReadiness.swift \
  Tests/CellTunnelCoreTests/RoutingStartReadinessTests.swift \
  Tests/CellTunnelCoreTests/RouteControlTests.swift \
  Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift \
  Sources/CellTunnelCore/RouteControl.swift \
  Sources/CellTunnelRelay/RelayRuntime.swift \
  Apps/macOS/Agent/AgentTunnelController+Control.swift \
  Apps/macOS/Agent/AgentTunnelController+Requests.swift \
  Apps/iOS/Services/RelayController.swift \
  Apps/iOS/Views/RelayScreenModel.swift \
  Apps/iOS/Views/MacStatusScreen.swift \
  Apps/iOS/Views/RelayStatusScreen.swift
git commit -S -m "Decide whether routing may start in one place" \
  -m "The app required only an active config while the agent also required a resolvable config and a selected peer, so the user saw a live switch, flipped it, and the agent refused the request." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 3: Accumulate byte totals in the agent

The lifetime byte totals advance only when the app's poll runs, so every byte moved while the app is closed is lost from the total. The store also folds a session reset only when it sees the counter drop, which it cannot see if the drop happens between two app launches. Its Catalyst seed path swaps the two directions, so a Mac upgrading from the earlier key pair inherits its upload total as its download total. The agent is running the whole time and is the only party that sees every reading.

**Files:**
- Create: `Sources/CellTunnelCore/LifetimeByteTotals.swift`
- Modify: `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Control.swift`
- Modify: `Apps/macOS/Agent/main.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Delete: `Apps/iOS/Services/LifetimeDataStore.swift`
- Modify: `Apps/iOS/CellTunnelPhoneApp.swift`
- Modify: `Apps/iOS/Testing/UITestFixture.swift`
- Modify: `Apps/iOS/Views/RelayStatusScreen.swift`
- Modify: `Apps/iOS/Views/MacStatusScreen.swift`
- Modify: `Apps/iOS/Views/PhoneContentView.swift`
- Modify: `Apps/iOS/Views/SetupScreen.swift`
- Modify: `Apps/iOS/Views/EnableTunnelScreen.swift`
- Test: `Tests/CellTunnelCoreTests/LifetimeByteTotalsTests.swift`

**Interfaces:**
- Consumes: `TunnelDaemonStatusSnapshot` as Task 2 left it.
- Produces:
  - `public struct LifetimeByteTotals: Codable, Equatable, Sendable` with `uploadBase`, `downloadBase`, `lastUpload`, `lastDownload` stored, computed `upload`, `download`, `total`, `init()`, `init(uploadBase:downloadBase:)`, and `mutating func record(upload: UInt64, download: UInt64)`.
  - `TunnelDaemonStatusSnapshot.lifetimeBytes: LifetimeByteTotals?`, last initializer parameter, defaulting to `nil`.
  - `RelayController.lifetimeTransferredBytes`, `lifetimeReceivedBytes`, `lifetimeTotalBytes` keep their names and types; only their source changes.
  - `RelayController.init` loses its `lifetimeStore:` parameter on both platforms.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/LifetimeByteTotalsTests.swift`:

```swift
//
//  LifetimeByteTotalsTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - LifetimeByteTotalsTests

/// Covers the fold that turns a restarting per-session counter into a total that only
/// grows. The session-reset case is the one the totals are for.
struct LifetimeByteTotalsTests {
  @Test func startsAtZero() {
    let totals = LifetimeByteTotals()

    #expect(totals.upload == 0)
    #expect(totals.download == 0)
    #expect(totals.total == 0)
  }

  @Test func reportsTheLiveSessionReading() {
    var totals = LifetimeByteTotals()

    totals.record(upload: 100, download: 250)

    #expect(totals.upload == 100)
    #expect(totals.download == 250)
    #expect(totals.total == 350)
  }

  @Test func foldsASessionResetIntoTheBase() {
    // The session restarted, so the counters dropped. The total must keep the finished
    // session's last reading rather than fall back to the new session's first one.
    var totals = LifetimeByteTotals()
    totals.record(upload: 100, download: 250)

    totals.record(upload: 10, download: 20)

    #expect(totals.upload == 110)
    #expect(totals.download == 270)
  }

  @Test func foldsEachDirectionOnItsOwn() {
    // Only upload restarted. Download must not be folded, or it double counts.
    var totals = LifetimeByteTotals()
    totals.record(upload: 100, download: 250)

    totals.record(upload: 5, download: 300)

    #expect(totals.upload == 105)
    #expect(totals.download == 300)
  }

  @Test func neverGoesBackwardsAcrossManyResets() {
    var totals = LifetimeByteTotals()
    for _ in 0..<3 {
      totals.record(upload: 40, download: 60)
      totals.record(upload: 1, download: 1)
    }

    #expect(totals.upload == 121)
    #expect(totals.download == 181)
  }

  @Test func resumesFromPersistedBases() {
    var totals = LifetimeByteTotals(uploadBase: 1000, downloadBase: 2000)

    totals.record(upload: 7, download: 9)

    #expect(totals.upload == 1007)
    #expect(totals.download == 2009)
  }

  @Test func travelsOnTheWire() {
    var totals = LifetimeByteTotals()
    totals.record(upload: 42, download: 84)
    let snapshot = TunnelDaemonStatusSnapshot(lifetimeBytes: totals)
    let encoded = try? JSONEncoder().encode(snapshot)
    let decoded = encoded.flatMap {
      try? JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: $0)
    }

    #expect(decoded?.lifetimeBytes?.upload == 42)
    #expect(decoded?.lifetimeBytes?.download == 84)
  }
}
```

Add `import Foundation` alongside the other imports for `JSONEncoder`.

Run `swift test --filter LifetimeByteTotalsTests`. Expected failure: `error: cannot find 'LifetimeByteTotals' in scope`.

- [ ] **Step 2: Add the fold**

Create `Sources/CellTunnelCore/LifetimeByteTotals.swift`:

```swift
//
//  LifetimeByteTotals.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

// MARK: - LifetimeByteTotals

/// Turns a per-session byte counter that restarts at zero into a total that only grows.
///
/// The relay's counters reset whenever a session restarts, so a finished session's last
/// reading has to be folded into a base before the new reading replaces it. Whoever
/// holds this has to see every reading: the app held it, and the app is not running
/// most of the time, so every byte moved while it was closed was dropped from the
/// total. The agent runs continuously and is the only party that sees them all.
///
/// The directions are the ones a person reads, resolved by the producer before it calls
/// `record`, because the relay's two ends count opposite directions under the same
/// names.
public struct LifetimeByteTotals: Codable, Equatable, Sendable {
  public var uploadBase: UInt64
  public var downloadBase: UInt64
  public var lastUpload: UInt64
  public var lastDownload: UInt64

  public init() {
    self.init(uploadBase: 0, downloadBase: 0)
  }

  /// Resumes from bases read back from storage, so an agent restart does not lose what
  /// earlier sessions moved.
  public init(uploadBase: UInt64, downloadBase: UInt64) {
    self.uploadBase = uploadBase
    self.downloadBase = downloadBase
    lastUpload = 0
    lastDownload = 0
  }

  public var upload: UInt64 {
    uploadBase &+ lastUpload
  }

  public var download: UInt64 {
    downloadBase &+ lastDownload
  }

  public var total: UInt64 {
    upload &+ download
  }

  /// Records one reading. A reading below the last one means that direction's session
  /// restarted, so the finished session's last reading folds into the base first. Each
  /// direction folds on its own, because a relay can restart one side's counter without
  /// the other.
  public mutating func record(upload: UInt64, download: UInt64) {
    if upload < lastUpload {
      uploadBase = uploadBase &+ lastUpload
    }
    if download < lastDownload {
      downloadBase = downloadBase &+ lastDownload
    }
    lastUpload = upload
    lastDownload = download
  }
}
```

- [ ] **Step 3: Put the totals on the wire**

In `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, add the stored property immediately after `routingStartReadiness`:

```swift
  /// The bytes this producer has moved over its whole life, in the directions a person
  /// reads them, accumulated across session restarts by the producer itself. `nil` from
  /// a producer that predates the field.
  public var lifetimeBytes: LifetimeByteTotals?
```

Add `lifetimeBytes: LifetimeByteTotals? = nil` as the last `init` parameter and `self.lifetimeBytes = lifetimeBytes` as the last assignment. In `renderedOutput`, after the `routing_readiness` block, add:

```swift
    if let lifetimeBytes {
      lines.append("lifetime_bytes_up=\(lifetimeBytes.upload)")
      lines.append("lifetime_bytes_down=\(lifetimeBytes.download)")
    }
```

Run `swift test --filter LifetimeByteTotalsTests`. Expected: all seven tests pass.

- [ ] **Step 4: Have the agent hold and persist the totals**

In `Apps/macOS/Agent/AgentTunnelController.swift`, add these stored properties beside the other `Mutex`-guarded agent state, and the constants beside the other private constants at the top of the file:

```swift
private let lifetimeUploadBaseKey = "lifetimeRelayBytesUploadBase"
private let lifetimeDownloadBaseKey = "lifetimeRelayBytesDownloadBase"
private let lifetimeAccrualIntervalSeconds = 10
```

```swift
  // The agent owns the running totals because it is the only party that sees every
  // reading; the app is closed most of the time. Behind a Mutex because the accrual
  // timer and a client's status call both reach it.
  let lifetimeBytes = Mutex(
    LifetimeByteTotals(
      uploadBase: UserDefaults(suiteName: cellTunnelAppGroupIdentifier)
        .flatMap { UInt64($0.string(forKey: lifetimeUploadBaseKey) ?? "") } ?? 0,
      downloadBase: UserDefaults(suiteName: cellTunnelAppGroupIdentifier)
        .flatMap { UInt64($0.string(forKey: lifetimeDownloadBaseKey) ?? "") } ?? 0
    )
  )
  var lifetimeAccrualTimer: DispatchSourceTimer?
```

The keys are the ones the app already wrote, so an upgrading Mac keeps its history. The earlier `lifetimeRelayBytesTransferredBase` and `lifetimeRelayBytesReceivedBase` pair is deliberately not read: its Catalyst seed swapped the directions, so inheriting it would report an upload total as a download total.

- [ ] **Step 5: Record every reading and publish the totals**

In `Apps/macOS/Agent/AgentTunnelController+Control.swift`, inside `augmented(_:profileState:)`, immediately before `return merged`, add:

```swift
    // The Mac counts its own traffic, so bytes leaving for the server are upload and
    // bytes arriving from it are download. Resolving the direction here, where the
    // producer is known, is what lets one stored pair serve both platforms.
    let counters = merged.macCounters ?? TunnelCounters()
    let totals = lifetimeBytes.withLock { existing -> LifetimeByteTotals in
      existing.record(upload: counters.relayBytesOut, download: counters.relayBytesIn)
      return existing
    }
    merged.lifetimeBytes = totals
    persistLifetimeBases(totals)
```

Add this method to the same extension, after `augmented`:

```swift
  // Writes the folded bases so an agent restart resumes rather than starts over. Only
  // the bases are written: the live session reading is re-read from the counters.
  private func persistLifetimeBases(_ totals: LifetimeByteTotals) {
    guard let defaults = UserDefaults(suiteName: cellTunnelAppGroupIdentifier) else {
      return
    }
    defaults.set(String(totals.uploadBase), forKey: lifetimeUploadBaseKey)
    defaults.set(String(totals.downloadBase), forKey: lifetimeDownloadBaseKey)
  }

  /// Folds the current counters on a slow timer, so bytes moved with no client
  /// connected still reach the total. Without this the totals would still advance only
  /// when someone asked for status, which is the defect being fixed.
  func startLifetimeAccrualTimer() {
    lifetimeAccrualTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + .seconds(lifetimeAccrualIntervalSeconds),
      repeating: .seconds(lifetimeAccrualIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      Task { _ = await self?.handleStatus() }
    }
    timer.resume()
    lifetimeAccrualTimer = timer
    logger.notice(
      """
      agent lifetime accrual timer started \
      intervalSeconds=\(lifetimeAccrualIntervalSeconds, privacy: .public)
      """
    )
  }
```

The timer drives `handleStatus()` rather than reading counters directly, because the Mac counters reach the agent only through the provider's forwarded snapshot, and `handleStatus()` is the one path that fetches it.

- [ ] **Step 6: Start the timer at agent startup**

In `Apps/macOS/Agent/main.swift`, immediately after the existing `Task { await controller.startAdvertising() }` line, add:

```swift
  // Byte totals have to accrue whether or not anything is asking for status, because
  // the app is closed for most of the time traffic moves.
  Task { await controller.startLifetimeAccrualTimer() }
```

If `startAdvertising` is not present, add the line immediately after `agentRuntime.start()`.

- [ ] **Step 7: Have the app render the published totals**

In `Apps/iOS/Services/RelayController.swift`, add to `RelayStatusSample` after `routingStartReadiness`:

```swift
  /// The producer's lifetime byte totals. The app renders them and accumulates
  /// nothing, because it does not see the readings taken while it is closed.
  var lifetimeUploadBytes: UInt64
  var lifetimeDownloadBytes: UInt64
```

In `RelayStatusSample.init(snapshot:)`, add as the last assignments:

```swift
    lifetimeUploadBytes = snapshot.lifetimeBytes?.upload ?? uploadBytes
    lifetimeDownloadBytes = snapshot.lifetimeBytes?.download ?? downloadBytes
```

A producer that predates the field reports the session reading, which is what it already knew.

Delete the stored `lifetimeStore` property, the `lifetimeStore:` parameter from both `init` overloads, and both `self.lifetimeStore = lifetimeStore` assignments. In `apply(_:)`, replace

```swift
    let lifetime = lifetimeStore.totals(
      sessionTransferred: sample.uploadBytes,
      sessionReceived: sample.downloadBytes
    )
    assign(\.lifetimeTransferredBytes, lifetime.transferred)
    assign(\.lifetimeReceivedBytes, lifetime.received)
    assign(\.lifetimeTotalBytes, lifetime.total)
```

with

```swift
    assign(\.lifetimeTransferredBytes, sample.lifetimeUploadBytes)
    assign(\.lifetimeReceivedBytes, sample.lifetimeDownloadBytes)
    assign(\.lifetimeTotalBytes, sample.lifetimeUploadBytes &+ sample.lifetimeDownloadBytes)
```

- [ ] **Step 8: Delete the app's store and every construction of it**

Delete `Apps/iOS/Services/LifetimeDataStore.swift`.

Remove the `lifetimeStore:` argument from every `RelayController(...)` call. The call sites are `Apps/iOS/CellTunnelPhoneApp.swift:44`, `Apps/iOS/Testing/UITestFixture.swift:60` and `:68`, `Apps/iOS/Views/RelayStatusScreen.swift:127`, `Apps/iOS/Views/MacStatusScreen.swift:262`, `Apps/iOS/Views/PhoneContentView.swift:45`, `Apps/iOS/Views/SetupScreen.swift:249`, and `Apps/iOS/Views/EnableTunnelScreen.swift:98`. In `UITestFixture.swift` also delete the now-unused `defaultsSuiteName` binding if nothing else reads it.

- [ ] **Step 9: Build and gate**

```bash
swift test --filter LifetimeByteTotalsTests
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```

Expected: tests pass, every gate `ok`, exit 0. `lint-deadcode` catches a missed `LifetimeDataStore` reference.

- [ ] **Step 10: Verify the totals advance with no app running**

With routing on and traffic flowing, and the Mac app closed:

```bash
Products/celltunnelctl status 2>&1 | grep lifetime_bytes
sleep 30
Products/celltunnelctl status 2>&1 | grep lifetime_bytes
```

Expected: both figures are strictly larger the second time. `sleep 30` covers three accrual ticks.

- [ ] **Step 11: Commit**

```bash
git add Sources/CellTunnelCore/LifetimeByteTotals.swift \
  Tests/CellTunnelCoreTests/LifetimeByteTotalsTests.swift \
  Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift \
  Apps/macOS/Agent Apps/iOS
git commit -S -m "Accumulate lifetime byte totals in the agent" \
  -m "The totals advanced only when the app polled, so every byte moved while the app was closed was dropped, and the Catalyst seed path swapped the two directions so an upgrading Mac inherited its upload total as its download total." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 4: Measure throughput against elapsed time

The speed reading treats each inter-poll byte delta as a per-second rate, so it is correct only when exactly one second passed. The poll baseline is dropped on every poll restart and `resumePolling` restarts unconditionally, so the first reading after every foreground is zero. The delta is computed with wrapping subtraction, so a session restart reports an enormous rate instead of nothing.

**Files:**
- Create: `Sources/CellTunnelCore/ThroughputMeter.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Delete: `Apps/iOS/Services/ThroughputCalculator.swift`
- Modify: `Apps/iOS/CellTunnelPhoneApp.swift`
- Modify: `Apps/iOS/Testing/UITestFixture.swift`
- Modify: `Apps/iOS/Views/RelayStatusScreen.swift`
- Modify: `Apps/iOS/Views/MacStatusScreen.swift`
- Modify: `Apps/iOS/Views/PhoneContentView.swift`
- Modify: `Apps/iOS/Views/SetupScreen.swift`
- Modify: `Apps/iOS/Views/EnableTunnelScreen.swift`
- Test: `Tests/CellTunnelCoreTests/ThroughputMeterTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public struct ThroughputMeter: Equatable, Sendable` with `public init()` and `public mutating func record(uploadBytes: UInt64, downloadBytes: UInt64, at timestamp: Double) -> ThroughputMeter.Rate`.
  - `public struct ThroughputMeter.Rate: Equatable, Sendable` with `uploadMegabitsPerSecond: Double` and `downloadMegabitsPerSecond: Double`.
  - `RelayController.init` loses its `throughput:` parameter on both platforms.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/ThroughputMeterTests.swift`:

```swift
//
//  ThroughputMeterTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - ThroughputMeterTests

/// Covers the rate a reading implies. The timestamp is the point: the earlier version
/// assumed exactly one second between readings and was wrong at every other interval.
struct ThroughputMeterTests {
  private let tolerance = 0.000_001

  @Test func firstReadingSeedsAndReportsZero() {
    var meter = ThroughputMeter()

    let rate = meter.record(uploadBytes: 1000, downloadBytes: 2000, at: 10)

    #expect(rate.uploadMegabitsPerSecond == 0)
    #expect(rate.downloadMegabitsPerSecond == 0)
  }

  @Test func oneMegabyteInOneSecondIsEightMegabits() {
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 10)

    let rate = meter.record(uploadBytes: 1_000_000, downloadBytes: 0, at: 11)

    #expect(abs(rate.uploadMegabitsPerSecond - 8) < tolerance)
  }

  @Test func fourSecondsApartIsAQuarterTheRate() {
    // The reading the earlier version got wrong: it divided by one poll, not by four
    // seconds, so a slow poll read four times too fast.
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 10)

    let rate = meter.record(uploadBytes: 1_000_000, downloadBytes: 0, at: 14)

    #expect(abs(rate.uploadMegabitsPerSecond - 2) < tolerance)
  }

  @Test func aPauseInReadingsStillReportsTheTrafficThatMoved() {
    // The app backgrounded for thirty seconds and came back. The reading covers the
    // gap rather than starting from zero, because the meter kept its baseline.
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 10)

    let rate = meter.record(uploadBytes: 30_000_000, downloadBytes: 0, at: 40)

    #expect(abs(rate.uploadMegabitsPerSecond - 8) < tolerance)
  }

  @Test func aSessionResetReportsZeroRatherThanAHugeRate() {
    // Wrapping subtraction on a restarted counter produced an astronomical figure.
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 5_000_000, downloadBytes: 5_000_000, at: 10)

    let rate = meter.record(uploadBytes: 100, downloadBytes: 100, at: 11)

    #expect(rate.uploadMegabitsPerSecond == 0)
    #expect(rate.downloadMegabitsPerSecond == 0)
  }

  @Test func twoReadingsAtTheSameInstantReportZero() {
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 10)

    let rate = meter.record(uploadBytes: 1_000_000, downloadBytes: 0, at: 10)

    #expect(rate.uploadMegabitsPerSecond == 0)
  }
}
```

Run `swift test --filter ThroughputMeterTests`. Expected failure: `error: cannot find 'ThroughputMeter' in scope`.

- [ ] **Step 2: Add the meter**

Create `Sources/CellTunnelCore/ThroughputMeter.swift`:

```swift
//
//  ThroughputMeter.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

// MARK: - Constants

private let bitsPerByte: Double = 8
private let bitsPerMegabit: Double = 1_000_000

// MARK: - ThroughputMeter

/// Converts successive byte totals into a rate, using the time between them.
///
/// The earlier version had no timestamp and treated each inter-reading delta as a
/// per-second rate, so it was correct only when exactly one second had passed, and its
/// owner dropped the baseline on every poll restart, so the first reading after each
/// foreground was zero. Carrying the timestamp means a reading is correct at any
/// spacing and the baseline survives a pause, which is what lets the pause report the
/// traffic that moved during it.
///
/// The totals arrive already resolved into user-facing directions, because the relay's
/// two ends count opposite directions under the same names.
public struct ThroughputMeter: Equatable, Sendable {
  /// One rate reading, in the unit the screen shows.
  public struct Rate: Equatable, Sendable {
    public let uploadMegabitsPerSecond: Double
    public let downloadMegabitsPerSecond: Double
  }

  private var baselineUpload: UInt64 = 0
  private var baselineDownload: UInt64 = 0
  private var baselineTimestamp: Double = 0
  private var hasBaseline = false

  public init() {}

  /// The rate these totals imply against the previous ones. A reading below the
  /// baseline means the session restarted, so it reseeds and reports nothing rather
  /// than the wrapped difference, which read as an astronomical rate. `timestamp` is
  /// seconds on any monotonic clock; only differences are used.
  public mutating func record(
    uploadBytes: UInt64,
    downloadBytes: UInt64,
    at timestamp: Double
  ) -> Rate {
    let elapsed = timestamp - baselineTimestamp
    let hasMeasurableInterval = hasBaseline && elapsed > 0
    let countersAdvanced = uploadBytes >= baselineUpload && downloadBytes >= baselineDownload
    guard hasMeasurableInterval, countersAdvanced else {
      baselineUpload = uploadBytes
      baselineDownload = downloadBytes
      baselineTimestamp = timestamp
      hasBaseline = true
      return Rate(uploadMegabitsPerSecond: 0, downloadMegabitsPerSecond: 0)
    }
    let uploadDelta = Double(uploadBytes - baselineUpload)
    let downloadDelta = Double(downloadBytes - baselineDownload)
    baselineUpload = uploadBytes
    baselineDownload = downloadBytes
    baselineTimestamp = timestamp
    return Rate(
      uploadMegabitsPerSecond: uploadDelta * bitsPerByte / bitsPerMegabit / elapsed,
      downloadMegabitsPerSecond: downloadDelta * bitsPerByte / bitsPerMegabit / elapsed
    )
  }
}
```

Run `swift test --filter ThroughputMeterTests`. Expected: all six tests pass.

- [ ] **Step 3: Have the controller own the meter and stop resetting it**

In `Apps/iOS/Services/RelayController.swift`, replace the stored property

```swift
  private var throughput: ThroughputCalculator
```

with

```swift
  // Owned rather than injected: it holds no policy, and the poll is the only caller.
  private var throughput = ThroughputMeter()
```

Delete the `throughput:` parameter from both `init` overloads and both `self.throughput = throughput` assignments.

In `startPolling()`, delete the line

```swift
    throughput.reset()
```

The baseline now survives a poll restart, which is what lets the first reading after a foreground report the traffic that moved while the app was away.

In `apply(_:)`, replace

```swift
    let rate = throughput.update(
      uploadBytes: sample.uploadBytes, downloadBytes: sample.downloadBytes)
    assign(\.uploadMbps, rate.upload)
    assign(\.downloadMbps, rate.download)
```

with

```swift
    let rate = throughput.record(
      uploadBytes: sample.uploadBytes,
      downloadBytes: sample.downloadBytes,
      at: ProcessInfo.processInfo.systemUptime
    )
    assign(\.uploadMbps, rate.uploadMegabitsPerSecond)
    assign(\.downloadMbps, rate.downloadMegabitsPerSecond)
```

`systemUptime` is monotonic, so a clock change cannot produce a negative interval.

- [ ] **Step 4: Delete the app's calculator and every construction of it**

Delete `Apps/iOS/Services/ThroughputCalculator.swift`.

Remove the `throughput:` argument from every `RelayController(...)` call, in the same eight call sites listed in Task 3 Step 8.

- [ ] **Step 5: Build and gate**

```bash
swift test --filter ThroughputMeterTests
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```

Expected: tests pass, every gate `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/CellTunnelCore/ThroughputMeter.swift \
  Tests/CellTunnelCoreTests/ThroughputMeterTests.swift \
  Apps/iOS
git commit -S -m "Measure throughput against elapsed time" \
  -m "The rate assumed exactly one second between readings, so it was wrong at every other spacing, the baseline was dropped on each poll restart so the first reading after every foreground was zero, and wrapping subtraction turned a session restart into an astronomical rate." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 5: Publish the routing phase instead of counting poll ticks

The app decides when a routing request has failed by counting status polls, eight for an off request and thirty-two for an on request. Those budgets are counted in poll ticks, and `suspendPolling` stops the loop when the app backgrounds, so a request made and then backgrounded never counts down. Returning to the app resumes a spinner that has been frozen for however long the app was away. The agent already tracks what the budgets are guessing at, in `settlingStartGeneration` and `lastStartError`.

**Files:**
- Create: `Sources/CellTunnelCore/TunnelRoutingPhase.swift`
- Modify: `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`
- Modify: `Sources/CellTunnelCore/RouteControl.swift`
- Modify: `Sources/CellTunnelRelay/RelayRuntime.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Control.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Test: `Tests/CellTunnelCoreTests/RouteControlTests.swift`
- Test: `Tests/CellTunnelCoreTests/TunnelRoutingPhaseTests.swift`

**Interfaces:**
- Consumes: `RoutingStartReadiness` and `RouteControl` as Task 2 left them.
- Produces:
  - `public enum TunnelRoutingPhase: String, Codable, Equatable, Sendable` with cases `connecting`, `idle`, `routing`, `stopping`, and `public static func resolve(isRoutingEnabled: Bool, areRoutesInstalled: Bool) -> TunnelRoutingPhase`.
  - `TunnelDaemonStatusSnapshot.routingPhase: TunnelRoutingPhase?`, last initializer parameter, defaulting to `nil`.
  - `RouteControl.init(isPeerConnected: Bool, phase: TunnelRoutingPhase, readiness: RoutingStartReadiness)`, replacing the six-parameter form. `RouteControl.isOn` and `isConnecting` keep their names and meaning.
  - `RelayController.setRouteTraffic(enabled:)` keeps its signature. `requestedRouting`, `routeIntentPollsRemaining`, `isRouteRequestPending`, `reconcileRouteIntent()`, `routeIntentTimeoutPolls`, and `routeConnectTimeoutPolls` are deleted.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/TunnelRoutingPhaseTests.swift`:

```swift
//
//  TunnelRoutingPhaseTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - TunnelRoutingPhaseTests

/// Covers the phase the daemon publishes, the value that replaced a poll-tick budget
/// the app counted down only while it was in the foreground.
struct TunnelRoutingPhaseTests {
  @Test func idleWhenOffAndNoRoutes() {
    let phase = TunnelRoutingPhase.resolve(isRoutingEnabled: false, areRoutesInstalled: false)

    #expect(phase == .idle)
  }

  @Test func connectingWhenOnBeforeRoutesLand() {
    let phase = TunnelRoutingPhase.resolve(isRoutingEnabled: true, areRoutesInstalled: false)

    #expect(phase == .connecting)
  }

  @Test func routingWhenOnAndRoutesInstalled() {
    let phase = TunnelRoutingPhase.resolve(isRoutingEnabled: true, areRoutesInstalled: true)

    #expect(phase == .routing)
  }

  @Test func stoppingWhenOffWhileRoutesRemain() {
    let phase = TunnelRoutingPhase.resolve(isRoutingEnabled: false, areRoutesInstalled: true)

    #expect(phase == .stopping)
  }
}
```

Run `swift test --filter TunnelRoutingPhaseTests`. Expected failure: `error: cannot find 'TunnelRoutingPhase' in scope`.

- [ ] **Step 2: Add the phase**

Create `Sources/CellTunnelCore/TunnelRoutingPhase.swift`:

```swift
//
//  TunnelRoutingPhase.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

// MARK: - TunnelRoutingPhase

/// Where the daemon is between the two settled routing states.
///
/// The client used to infer this by counting status polls after it sent a request, so
/// the inference stopped whenever the poll loop stopped, and an app that backgrounded
/// mid-connect came back to a spinner frozen for the whole time it was away. The daemon
/// knows the answer without counting anything, so it says so and no client keeps a
/// timer.
public enum TunnelRoutingPhase: String, Codable, Equatable, Sendable {
  case connecting
  case idle
  case routing
  case stopping

  /// Resolves the phase from the intent the daemon holds and the routes it has actually
  /// installed. The two settled states are both on and both off; the two in-between
  /// states are the ones a client shows a spinner for.
  public static func resolve(
    isRoutingEnabled: Bool,
    areRoutesInstalled: Bool
  ) -> TunnelRoutingPhase {
    if isRoutingEnabled {
      return areRoutesInstalled ? .routing : .connecting
    }
    return areRoutesInstalled ? .stopping : .idle
  }
}
```

Run `swift test --filter TunnelRoutingPhaseTests`. Expected: all four tests pass.

- [ ] **Step 3: Put the phase on the wire and fill it from both producers**

In `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, add the stored property after `lifetimeBytes`:

```swift
  /// Where the producer is between the two settled routing states, so a client shows a
  /// spinner without keeping a timer of its own. `nil` from a producer that predates
  /// the field.
  public var routingPhase: TunnelRoutingPhase?
```

Add `routingPhase: TunnelRoutingPhase? = nil` as the last `init` parameter with the matching assignment, and in `renderedOutput`, after the lifetime block:

```swift
    if let routingPhase {
      lines.append("routing_phase=\(routingPhase.rawValue)")
    }
```

In `Apps/macOS/Agent/AgentTunnelController+Control.swift`, inside `augmented(_:profileState:)`, immediately after `merged.routingIntentEnabled = TunnelRoutingIntent(enabled: routingEnabled)`, add:

```swift
    merged.routingPhase = TunnelRoutingPhase.resolve(
      isRoutingEnabled: routingEnabled,
      areRoutesInstalled: merged.routeState == .installed
    )
```

In `Sources/CellTunnelRelay/RelayRuntime.swift`, inside `statusSnapshot()`, add after the `routingStartReadiness` argument:

```swift
      routingPhase: TunnelRoutingPhase.resolve(
        isRoutingEnabled: state.routingIntent?.isEnabled ?? false,
        areRoutesInstalled: state.routeInstalled
      )
```

- [ ] **Step 4: Reduce the switch to the published phase**

In `Sources/CellTunnelCore/RouteControl.swift`, replace the whole initializer and its doc comment with:

```swift
  /// Derives the switch state from the phase the daemon publishes and its own readiness
  /// answer, so the switch shows what the daemon is actually doing rather than what the
  /// client last asked for. There is no optimistic client state and no timeout: the
  /// daemon returns a fresh snapshot from the request that changed the phase, so the
  /// switch follows on the reply rather than on a guess. Pure: the same inputs always
  /// produce the same value.
  public init(
    isPeerConnected: Bool,
    phase: TunnelRoutingPhase,
    readiness: RoutingStartReadiness
  ) {
    let resolvedPresentation: RouteControlPresentation
    if !isPeerConnected {
      resolvedPresentation = .hidden
    } else if !readiness.canProceed {
      resolvedPresentation = .disabled(reason: readiness)
    } else {
      resolvedPresentation = .enabled
    }
    presentation = resolvedPresentation
    // The switch reads on only when it is the enabled control, so a hidden or disabled
    // switch never shows on even while the daemon is still tearing a session down.
    let isEnabled = resolvedPresentation == .enabled
    isOn = isEnabled && (phase == .connecting || phase == .routing)
    isConnecting = isEnabled && phase == .connecting
  }
```

- [ ] **Step 5: Rewrite the switch tests against the phase**

Replace the whole body of `Tests/CellTunnelCoreTests/RouteControlTests.swift` below its header comment with:

```swift
import CellTunnelCore
import Testing

// MARK: - RouteControlTests

/// Covers the observable states of the single Route traffic switch. The engaged signal
/// is the phase the daemon publishes, never a local flag and never a poll-tick budget.
struct RouteControlTests {
  @Test func hiddenWhenNoPeer() {
    let control = RouteControl(
      isPeerConnected: false, phase: .idle, readiness: .noActiveConfig)

    #expect(control.presentation == .hidden)
    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }

  @Test func offWhenHiddenEvenWhileRouting() {
    // No peer can carry traffic, so the switch is hidden and must not read on even if
    // the daemon has not finished tearing the session down.
    let control = RouteControl(
      isPeerConnected: false, phase: .routing, readiness: .ready)

    #expect(control.presentation == .hidden)
    #expect(control.isOn == false)
  }

  @Test func disabledWhenNoActiveConfig() {
    let control = RouteControl(
      isPeerConnected: true, phase: .idle, readiness: .noActiveConfig)

    #expect(control.presentation == .disabled(reason: .noActiveConfig))
    #expect(control.isOn == false)
  }

  @Test func disabledWhenNoSelectedPeer() {
    // The case the app used to draw as a live switch the agent then refused.
    let control = RouteControl(
      isPeerConnected: true, phase: .idle, readiness: .noSelectedPeer)

    #expect(control.presentation == .disabled(reason: .noSelectedPeer))
    #expect(control.isOn == false)
  }

  @Test func offWhenDisabledEvenIfRouting() {
    // The active config was cleared while routing: the switch must read off beside its
    // hint rather than show on next to a reason the user cannot act on.
    let control = RouteControl(
      isPeerConnected: true, phase: .routing, readiness: .noActiveConfig)

    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }

  @Test func readyToRouteWhenIdle() {
    let control = RouteControl(isPeerConnected: true, phase: .idle, readiness: .ready)

    #expect(control.presentation == .enabled)
    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }

  @Test func onAndSpinningWhileConnecting() {
    let control = RouteControl(
      isPeerConnected: true, phase: .connecting, readiness: .ready)

    #expect(control.isOn == true)
    #expect(control.isConnecting == true)
  }

  @Test func onAndSettledWhileRouting() {
    let control = RouteControl(isPeerConnected: true, phase: .routing, readiness: .ready)

    #expect(control.isOn == true)
    #expect(control.isConnecting == false)
  }

  @Test func staysOnWhenTheLinkBrieflyDrops() {
    // A mid-session link drop leaves the intent on and the routes withdrawn, which the
    // daemon reports as connecting. The switch stays on so the user need not touch it.
    let control = RouteControl(
      isPeerConnected: true, phase: .connecting, readiness: .ready)

    #expect(control.isOn == true)
    #expect(control.isConnecting == true)
  }

  @Test func offWhileStopping() {
    // Turning off with routes still installed reads off at once, so the switch follows
    // the user's action as the session tears down.
    let control = RouteControl(
      isPeerConnected: true, phase: .stopping, readiness: .ready)

    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }
}
```

Run `swift test --filter RouteControlTests`. Expected: all ten tests pass.

- [ ] **Step 6: Delete the app's poll-tick budgets**

In `Apps/iOS/Services/RelayController.swift`, delete the two constants and their comments:

```swift
// Status polls an unconfirmed routing-off request waits for the agent to apply
// before the switch reverts to the real state, so a request that never lands cannot
// leave the spinner spinning forever. Turning off stops the relay at once, so the
// off budget is short; at the 1s poll cadence this is an 8s budget.
private let routeIntentTimeoutPolls = 8
// Turning on starts a relay session whose connect can take up to the session connect
// timeout (~30s), so the on budget is long enough to cover the connect and the
// spinner does not snap back to off mid-connect; at the 1s poll cadence this is a 32s
// budget.
private let routeConnectTimeoutPolls = 32
```

Delete the two stored properties and their comments:

```swift
  /// The routing value the user last requested, held while a request is pending so
  /// the switch shows the requested state until the agent's real `routeState`
  /// confirms it. Only meaningful while `routeIntentPollsRemaining` is positive.
  private var requestedRouting = false
  // Status polls left before an unconfirmed routing request reverts to the real
  // state; a positive value means a request is pending, counted down each poll.
  private var routeIntentPollsRemaining = 0
```

Delete the call to `reconcileRouteIntent()` in `apply(_:)`, and delete `isRouteRequestPending` and `reconcileRouteIntent()` in full from the `Routing control` extension.

Add the phase to `RelayStatusSample` beside `routingIntentEnabled`:

```swift
  /// Where the producer is between the two settled routing states, the value behind the
  /// switch's spinner. A producer that predates the field reports nothing, so the phase
  /// falls back to what the intent and the routes imply.
  var routingPhase: TunnelRoutingPhase
```

In `RelayStatusSample.init(snapshot:)`, immediately after the `routingIntentEnabled` assignment, add:

```swift
    routingPhase =
      snapshot.routingPhase
      ?? TunnelRoutingPhase.resolve(
        isRoutingEnabled: routingIntentEnabled,
        areRoutesInstalled: routesInstalledFallback
      )
```

Add the observable property beside `routingIntentEnabled` and assign it in `apply(_:)`:

```swift
  /// The daemon's routing phase, the value the switch and its spinner read.
  var routingPhase: TunnelRoutingPhase = .idle
```

```swift
    assign(\.routingPhase, sample.routingPhase)
```

Replace `routeControl` with:

```swift
  /// The derived state of the single Route traffic switch, computed from the phase the
  /// daemon publishes so both screens render it the same way and no client keeps a
  /// timeout of its own.
  var routeControl: RouteControl {
    RouteControl(
      isPeerConnected: connectedPeerName != nil,
      phase: routingPhase,
      readiness: routingStartReadiness
    )
  }
```

Replace `setRouteTraffic(enabled:)` with:

```swift
  func setRouteTraffic(enabled: Bool) async {
    logger.notice(
      "relay controller route traffic requested enabled=\(enabled, privacy: .public)")
    // The switch follows the daemon's phase, and the daemon changes it before the call
    // returns, so nothing here predicts the result or times it out.
    routingPhase = enabled ? .connecting : .stopping
    await backend.setRouting(enabled: enabled)
  }
```

Setting the phase locally is not a prediction that needs unwinding: the next snapshot overwrites it, and a rejected request comes back with `lastError` set and the phase already back at `idle`.

- [ ] **Step 7: Build and gate**

```bash
swift test --filter TunnelRoutingPhaseTests
swift test --filter RouteControlTests
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```

Expected: tests pass, every gate `ok`, exit 0.

- [ ] **Step 8: Verify the phase survives a backgrounded app**

Turn routing on in the Mac app, background the app immediately, wait sixty seconds, then:

```bash
Products/celltunnelctl status 2>&1 | grep routing_phase
```

Expected: `routing_phase=routing`, and bringing the app forward shows a settled on switch with no spinner, rather than a spinner resuming a frozen countdown.

- [ ] **Step 9: Commit**

```bash
git add Sources/CellTunnelCore/TunnelRoutingPhase.swift \
  Tests/CellTunnelCoreTests/TunnelRoutingPhaseTests.swift \
  Tests/CellTunnelCoreTests/RouteControlTests.swift \
  Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift \
  Sources/CellTunnelCore/RouteControl.swift \
  Sources/CellTunnelRelay/RelayRuntime.swift \
  Apps/macOS/Agent/AgentTunnelController+Control.swift \
  Apps/iOS/Services/RelayController.swift
git commit -S -m "Publish the routing phase from the daemon" \
  -m "The app decided a routing request had failed by counting status polls, and the poll loop stops when the app backgrounds, so a request made and then backgrounded never counted down and returning to the app resumed a frozen spinner." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 6: Publish which situation the machine is in

Both status state machines live in the app, as nine-branch and six-branch precedence chains over eight and five separate flags, with no tests. `celltunnelctl` cannot reach either, so it prints raw fields while the app prints a sentence, and the two can disagree about the same agent. The status word is also derived in two places: `RelayScreenModel.statusLabel` overrides the enum's own label with a connecting word, so moving only the enums would leave that behind.

**Files:**
- Create: `Sources/CellTunnelCore/RelaySituation.swift`
- Create: `Apps/iOS/Views/RelaySituationPresentation.swift`
- Delete: `Apps/iOS/Views/MacRelayStatus.swift`
- Delete: `Apps/iOS/Views/PhoneRelayStatus.swift`
- Modify: `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`
- Modify: `Sources/CellTunnelRelay/RelayRuntime.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Control.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Modify: `Apps/iOS/Views/RelayScreenModel.swift`
- Test: `Tests/CellTunnelCoreTests/RelaySituationTests.swift`

**Interfaces:**
- Consumes: `RoutingStartReadiness` from Task 2 and `TunnelRoutingPhase` from Task 5.
- Produces:
  - `public enum RelaySituation: String, Codable, Equatable, Sendable` with cases `connecting`, `failed`, `noActiveConfig`, `noAgent`, `noConfigImported`, `noPeerSelected`, `noPeersFound`, `notProvisioned`, `readyToRoute`, `routing`, `vpnProfileDisabled`.
  - `public func macRelaySituation(snapshot: TunnelDaemonStatusSnapshot, hasImportedConfig: Bool, peersFound: Bool) -> RelaySituation`
  - `public func phoneRelaySituation(snapshot: TunnelDaemonStatusSnapshot, peersFound: Bool) -> RelaySituation`
  - `TunnelDaemonStatusSnapshot.situation: RelaySituation?`, last initializer parameter, defaulting to `nil`.
  - App-side: `RelaySituation.label: String`, `RelaySituation.showsSpeed: Bool`, `RelaySituation.action: RelayHeroAction?`, and on Catalyst `RelaySituation.uiTier: RelayUITier`. `RelayUITier` moves to the new app file unchanged.
  - `RelayScreenModel.status: RelaySituation` on both platforms, replacing the two per-platform types. `RelayScreenModel.statusLabel` becomes `status.label`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/RelaySituationTests.swift`:

```swift
//
//  RelaySituationTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - RelaySituationTests

/// Covers which situation each producer reports. Neither chain had a test before, and
/// the order of the branches is the whole behavior, so each test names the pair of
/// situations whose precedence it pins.
struct RelaySituationTests {
  private func macSnapshot(
    lastError: String? = nil,
    vpnProfileState: TunnelVPNProfileState? = .enabled,
    connectedPeerName: String? = "iPhone",
    activeConfigID: UUID? = UUID(),
    routingPhase: TunnelRoutingPhase = .idle
  ) -> TunnelDaemonStatusSnapshot {
    TunnelDaemonStatusSnapshot(
      lastError: lastError,
      connectedPeerName: connectedPeerName,
      activeConfigID: activeConfigID,
      vpnProfileState: vpnProfileState,
      routingPhase: routingPhase
    )
  }

  // MARK: - Mac

  @Test func macReportsFailureAboveEverythingElse() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(lastError: "boom"), hasImportedConfig: true, peersFound: true)

    #expect(situation == .failed)
  }

  @Test func macAsksForAConfigBeforeItAsksForTheProfile() {
    // Deleting every config leaves the profile in place, and re-enabling a profile with
    // nothing to route accomplishes nothing, so the library comes first.
    let situation = macRelaySituation(
      snapshot: macSnapshot(vpnProfileState: .disabled),
      hasImportedConfig: false,
      peersFound: true
    )

    #expect(situation == .noConfigImported)
  }

  @Test func macAsksForTheProfileOnceAConfigExists() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(vpnProfileState: .disabled),
      hasImportedConfig: true,
      peersFound: true
    )

    #expect(situation == .vpnProfileDisabled)
  }

  @Test func macAsksForAnActiveConfigOnceAPeerIsConnected() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(activeConfigID: nil), hasImportedConfig: true, peersFound: true)

    #expect(situation == .noActiveConfig)
  }

  @Test func macIsConnectingWhileRoutesAreLanding() {
    // The connecting word used to be applied by the screen on top of the state, in a
    // second place, so it is part of the situation now.
    let situation = macRelaySituation(
      snapshot: macSnapshot(routingPhase: .connecting),
      hasImportedConfig: true,
      peersFound: true
    )

    #expect(situation == .connecting)
  }

  @Test func macIsRoutingOnceRoutesAreInstalled() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(routingPhase: .routing), hasImportedConfig: true, peersFound: true)

    #expect(situation == .routing)
  }

  @Test func macIsReadyToRouteWithAPeerAndAConfig() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(), hasImportedConfig: true, peersFound: true)

    #expect(situation == .readyToRoute)
  }

  @Test func macSearchesWhenNoPeerIsListed() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(connectedPeerName: nil),
      hasImportedConfig: true,
      peersFound: false
    )

    #expect(situation == .noPeersFound)
  }

  @Test func macAsksForAPeerWhenOneIsListedButNotConnected() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(connectedPeerName: nil),
      hasImportedConfig: true,
      peersFound: true
    )

    #expect(situation == .noPeerSelected)
  }

  // MARK: - iPhone

  @Test func phoneAsksToInstallTheTunnelFirst() {
    let situation = phoneRelaySituation(
      snapshot: TunnelDaemonStatusSnapshot(peerState: .notSelected), peersFound: true)

    #expect(situation == .notProvisioned)
  }

  @Test func phoneIsRoutingOnceRoutesAreInstalled() {
    let snapshot = TunnelDaemonStatusSnapshot(
      peerState: .relaySelected,
      connectedPeerName: "Mac",
      routingPhase: .routing
    )

    #expect(phoneRelaySituation(snapshot: snapshot, peersFound: true) == .routing)
  }

  @Test func phoneNeverReportsAMacOnlySituation() {
    // The iPhone installs no agent and holds no library, so those situations are not
    // reachable from its snapshot no matter what it carries.
    let snapshot = TunnelDaemonStatusSnapshot(
      peerState: .relaySelected, connectedPeerName: "Mac", activeConfigID: nil)
    let situation = phoneRelaySituation(snapshot: snapshot, peersFound: true)

    #expect(situation != .noAgent)
    #expect(situation != .noActiveConfig)
    #expect(situation != .noConfigImported)
  }
}
```

Add `import Foundation` for `UUID`.

Run `swift test --filter RelaySituationTests`. Expected failure: `error: cannot find 'macRelaySituation' in scope`.

- [ ] **Step 2: Add the situation and both chains**

Create `Sources/CellTunnelCore/RelaySituation.swift`:

```swift
//
//  RelaySituation.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

// MARK: - RelaySituation

/// Which situation the machine is in, the one value a client renders its status from.
///
/// Two precedence chains decided this inside the app, over eight and five separate
/// flags, with no test between them, and the command-line tool could reach neither, so
/// the two surfaces could describe the same agent differently. The situation travels on
/// the wire and each client writes its own words for it, which keeps wording and
/// translation in the client while the decision stays here.
///
/// One set covers both producers. A situation only one of them can reach is simply
/// unreachable from the other's snapshot rather than absent from the type, which is
/// what lets one printed line serve both.
public enum RelaySituation: String, Codable, Equatable, Sendable {
  case connecting
  case failed
  case noActiveConfig = "no-active-config"
  case noAgent = "no-agent"
  case noConfigImported = "no-config-imported"
  case noPeerSelected = "no-peer-selected"
  case noPeersFound = "no-peers-found"
  case notProvisioned = "not-provisioned"
  case readyToRoute = "ready-to-route"
  case routing
  case vpnProfileDisabled = "vpn-profile-disabled"
}

// MARK: - Mac

/// The Mac's situation. A failure wins, then the library must hold a configuration,
/// then the saved VPN profile must be switched on. The library comes before the profile
/// because deleting every configuration leaves the profile in place, and re-enabling a
/// profile with nothing to route accomplishes nothing.
///
/// An established peer link decides the rest before discovery, since a live link means
/// the screen is connected whether or not this side browsed for it. The split between
/// routing and ready is the agent's own phase, never a local running flag. Without a
/// link, no dialed-in iPhone is the searching situation and a listed but unconnected one
/// is the select situation.
///
/// `hasImportedConfig` and `peersFound` are separate inputs because the caller decides
/// what counts: the Mac reads its dialed-in roster for peers, and its library for
/// configurations. `noAgent` is never returned here, because an absent agent produces no
/// snapshot at all and only the client can observe that.
public func macRelaySituation(
  snapshot: TunnelDaemonStatusSnapshot,
  hasImportedConfig: Bool,
  peersFound: Bool
) -> RelaySituation {
  if let lastError = snapshot.lastError, !lastError.isEmpty {
    return .failed
  }
  if !hasImportedConfig {
    return .noConfigImported
  }
  if snapshot.vpnProfileState == .disabled {
    return .vpnProfileDisabled
  }
  guard snapshot.connectedPeerName != nil else {
    return peersFound ? .noPeerSelected : .noPeersFound
  }
  if snapshot.activeConfigID == nil {
    return .noActiveConfig
  }
  return routingSituation(phase: snapshot.routingPhase)
}

// MARK: - iPhone

/// The iPhone's situation, decided the same way from the facts the iPhone has. It
/// installs no agent and holds no configuration library, so it names its saved tunnel
/// directly and reaches neither Mac-only situation.
public func phoneRelaySituation(
  snapshot: TunnelDaemonStatusSnapshot,
  peersFound: Bool
) -> RelaySituation {
  if let lastError = snapshot.lastError, !lastError.isEmpty {
    return .failed
  }
  if snapshot.peerState == .notSelected {
    return .notProvisioned
  }
  guard snapshot.connectedPeerName != nil else {
    return peersFound ? .noPeerSelected : .noPeersFound
  }
  return routingSituation(phase: snapshot.routingPhase)
}

// MARK: - Shared tail

// The connected tail is identical on both sides, and the connecting word used to be
// applied by the screen on top of the finished state, which is how the status word came
// to be derived in two places. It belongs to the situation.
private func routingSituation(phase: TunnelRoutingPhase?) -> RelaySituation {
  switch phase {
  case .connecting:
    return .connecting
  case .routing:
    return .routing
  case .idle, .stopping, .none:
    return .readyToRoute
  }
}
```

Run `swift test --filter RelaySituationTests`. Expected: all twelve tests pass.

- [ ] **Step 3: Put the situation on the wire and fill it from both producers**

In `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, add after `routingPhase`:

```swift
  /// Which situation the producer says the machine is in, so every client renders one
  /// decision rather than re-deriving it. `nil` from a producer that predates the field.
  public var situation: RelaySituation?
```

Add `situation: RelaySituation? = nil` as the last `init` parameter with its assignment, and in `renderedOutput`, after the `routing_phase` block:

```swift
    if let situation {
      lines.append("situation=\(situation.rawValue)")
    }
```

In `Apps/macOS/Agent/AgentTunnelController+Control.swift`, at the very end of `augmented(_:profileState:)`, immediately before `return merged`, add:

```swift
    // Computed last, because it reads the fields this method just filled in.
    merged.situation = macRelaySituation(
      snapshot: merged,
      hasImportedConfig: !(merged.configLibrary ?? []).isEmpty,
      peersFound: !(merged.connectedPeers ?? []).isEmpty
    )
```

In `Sources/CellTunnelRelay/RelayRuntime.swift`, replace the `return TunnelDaemonStatusSnapshot(...)` in `statusSnapshot()` with a local binding so the situation can read the finished value:

```swift
    var snapshot = TunnelDaemonStatusSnapshot(
```

Keep every existing argument unchanged, close the call with `)`, then add:

```swift
    snapshot.situation = phoneRelaySituation(
      snapshot: snapshot,
      peersFound: !state.discoveredServices.isEmpty
    )
    return snapshot
```

- [ ] **Step 4: Give the app the words**

Create `Apps/iOS/Views/RelaySituationPresentation.swift`:

```swift
//
//  RelaySituationPresentation.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore

// MARK: - RelayUITier

/// Which screen the status renders. A setup situation takes over the whole screen with
/// a single guided action; every other situation shows the reduced dashboard with its
/// rows, peers, and action. Only the Mac chooses its screen this way.
enum RelayUITier: Equatable {
  case full
  case reduced
}

// MARK: - Presentation

/// The app's words and controls for each situation the daemon publishes. The daemon
/// says which situation the machine is in and this file says what that reads like, so
/// wording changes never touch a rule and `celltunnelctl` phrases the same situations
/// its own way. The labels are neutral placeholders rather than final copy.
extension RelaySituation {
  /// The neutral status word shown as the switch's left label and the status line.
  var label: String {
    switch self {
    case .connecting:
      return "Connecting"
    case .failed:
      return "Error"
    case .noActiveConfig:
      return "No config selected"
    case .noAgent:
      return "Agent not installed"
    case .noConfigImported:
      return "No configuration imported"
    case .noPeerSelected:
      return "No peer selected"
    case .noPeersFound:
      return "Searching for peers"
    case .notProvisioned:
      return "Tunnel not installed"
    case .readyToRoute:
      return "Ready to route traffic"
    case .routing:
      return "Routing traffic"
    case .vpnProfileDisabled:
      return "VPN turned off"
    }
  }

  /// Whether the live `Current Speed` section shows, only while routing.
  var showsSpeed: Bool {
    self == .routing
  }

  /// The offered action, or none when the routing switch is the only control the
  /// situation needs.
  var action: RelayHeroAction? {
    switch self {
    case .failed:
      return .retry
    case .noAgent:
      return .installAgent
    case .noConfigImported:
      return .importConfig
    case .noPeerSelected:
      return .selectPeer
    case .vpnProfileDisabled:
      return .enableVPN
    case .connecting, .noActiveConfig, .noPeersFound, .notProvisioned, .readyToRoute,
      .routing:
      return nil
    }
  }

  #if targetEnvironment(macCatalyst)

    /// Which screen renders this situation: the full guided setup for the three setup
    /// situations, the reduced dashboard for everything else.
    var uiTier: RelayUITier {
      switch self {
      case .noAgent, .noConfigImported, .vpnProfileDisabled:
        return .full
      case .connecting, .failed, .noActiveConfig, .noPeerSelected, .noPeersFound,
        .notProvisioned, .readyToRoute, .routing:
        return .reduced
      }
    }

  #endif
}
```

Delete `Apps/iOS/Views/MacRelayStatus.swift` and `Apps/iOS/Views/PhoneRelayStatus.swift`.

- [ ] **Step 5: Have the screen model read the published situation**

In `Apps/iOS/Services/RelayController.swift`, add the field to `RelayStatusSample` after `routingPhase`:

```swift
  /// Which situation the producer says the machine is in. A producer that predates the
  /// field reports nothing, and the app falls back to searching, the situation a client
  /// with nothing to show is genuinely in.
  var situation: RelaySituation
```

Assign it in `init(snapshot:)`:

```swift
    situation = snapshot.situation ?? .noPeersFound
```

Add the observable property beside `routingPhase` and assign it in `apply(_:)`:

```swift
  /// Which situation the daemon says the machine is in, the value the screens render.
  var situation: RelaySituation = .noPeersFound
```

```swift
    assign(\.situation, sample.situation)
```

In `Apps/iOS/Views/RelayScreenModel.swift`, delete the `connectingStatusLabel` constant, and replace `statusLabel` with:

```swift
  /// The status word the screens show. The daemon decides the situation, including the
  /// connecting one, so the word is no longer derived in a second place here.
  var statusLabel: String {
    status.label
  }
```

Delete the private `peersAvailable` property, which nothing reads once the chains are gone.

Replace the whole `Status` extension at the end of the file with:

```swift
// MARK: - Status

/// The situation the screens render, read straight from the daemon. The app used to
/// derive this from a pile of separate flags, in a different chain per platform, so the
/// two surfaces could disagree about the same agent.
extension RelayScreenModel {
  var status: RelaySituation {
    #if targetEnvironment(macCatalyst)
      // The agent's absence is the one situation the agent cannot report, because an
      // absent agent produces no snapshot at all, so the client observes it.
      if !controller.isAgentInstalled {
        return .noAgent
      }
    #endif
    return controller.situation
  }
}
```

In the same file, `uiTier` already reads `status.uiTier` and needs no change.

- [ ] **Step 6: Build and gate**

```bash
swift test --filter RelaySituationTests
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```

Expected: tests pass, every gate `ok`, exit 0. Fix every reference to the two deleted enums that the compiler names; `MacStatusScreen.swift`, `RelayStatusScreen.swift`, and `SetupScreen.swift` are the likely ones.

- [ ] **Step 7: Verify both surfaces agree**

```bash
Products/celltunnelctl status 2>&1 | grep situation
```

Expected: the printed situation matches what the Mac app's status line says, for at least two different states reached in a row, such as `no-peers-found` then `ready-to-route`.

- [ ] **Step 8: Commit**

```bash
git add Sources/CellTunnelCore/RelaySituation.swift \
  Tests/CellTunnelCoreTests/RelaySituationTests.swift \
  Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift \
  Sources/CellTunnelRelay/RelayRuntime.swift \
  Apps/macOS/Agent/AgentTunnelController+Control.swift \
  Apps/iOS
git commit -S -m "Publish which situation the machine is in" \
  -m "Both status state machines were untested precedence chains inside the app that the command-line tool could not reach, so the two surfaces could describe the same agent differently, and the status word was derived again on top of them in the screen model." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 7: Store a configuration without activating it

Adding a configuration takes two requests. The agent activates every imported configuration unconditionally, so the app captures the prior active id, pins it so the poll masks the intermediate state, imports, then sends a second request to undo the activation. A crash or a dropped connection between the two leaves the wrong configuration active. `celltunnelctl configs import` sends only the first request, so the two clients disagree about what adding a configuration means.

**Files:**
- Modify: `Sources/CellTunnelCore/AgentControlRequest.swift`
- Modify: `Sources/CellTunnelCore/TunnelControlCLIAction.swift`
- Modify: `Sources/CellTunnelCore/AgentClient.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Configs.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Requests.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Modify: `Apps/iOS/Services/RelayController+ConfigLibrary.swift`
- Modify: `Apps/iOS/Services/AgentRelayBackend.swift`
- Modify: `Apps/iOS/Services/ConfigLibraryBackend.swift`
- Test: `Tests/CellTunnelCoreTests/ConfigImportActivationTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `AgentControlRequest.importConfig(name: String, text: String, activate: Bool)`, replacing the two-argument case. A decoded envelope with no `configActivate` key reads `activate: true`.
  - `TunnelControlClientProtocol.importConfig(name: String, text: String, activate: Bool) async throws -> TunnelDaemonStatusSnapshot`
  - `ConfigsCommand.importFile(path: String, activate: Bool)`, parsed from `configs import <path> [--no-activate]`.
  - `ConfigLibraryBackend.importConfig(name: String, text: String, activate: Bool) async throws`
  - `RelayController.createConfig(name:text:)` keeps its signature. `pinnedActiveConfigID` is deleted.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/ConfigImportActivationTests.swift`:

```swift
//
//  ConfigImportActivationTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - ConfigImportActivationTests

/// Covers the request that adds a configuration. Storing without activating had to be
/// two requests with a client-side undo between them, so the wire now carries the
/// choice and both clients send one request.
struct ConfigImportActivationTests {
  private func roundTrip(_ request: AgentControlRequest) -> AgentControlRequest? {
    guard let encoded = try? JSONEncoder().encode(AgentControlEnvelope(request: request)),
      let decoded = try? JSONDecoder().decode(AgentControlEnvelope.self, from: encoded)
    else {
      return nil
    }
    return decoded.request
  }

  @Test func carriesTheActivateChoice() {
    let decoded = roundTrip(.importConfig(name: "home", text: "[Interface]", activate: false))

    guard case .importConfig(let name, let text, let activate) = decoded else {
      Issue.record("expected an importConfig request, got \(String(describing: decoded))")
      return
    }
    #expect(name == "home")
    #expect(text == "[Interface]")
    #expect(activate == false)
  }

  @Test func carriesActivateWhenAsked() {
    let decoded = roundTrip(.importConfig(name: "home", text: "[Interface]", activate: true))

    guard case .importConfig(_, _, let activate) = decoded else {
      Issue.record("expected an importConfig request, got \(String(describing: decoded))")
      return
    }
    #expect(activate == true)
  }

  @Test func anOlderEnvelopeStillActivates() {
    // A client that predates the field sends no key, and the behavior it expected was
    // that importing activates, so the missing key has to mean exactly that.
    let json = Data(#"{"version":2,"request":{"kind":"importConfig","configName":"home","configText":"[Interface]"}}"#.utf8)
    let decoded = try? JSONDecoder().decode(AgentControlEnvelope.self, from: json)

    guard case .importConfig(_, _, let activate) = decoded?.request else {
      Issue.record("expected an importConfig request")
      return
    }
    #expect(activate == true)
  }

  @Test func theCommandLineCanImportWithoutActivating() {
    let action = try? TunnelControlCLIAction.parse(
      arguments: ["configs", "import", "/tmp/home.conf", "--no-activate"])

    #expect(action == .configs(.importFile(path: "/tmp/home.conf", activate: false)))
  }

  @Test func theCommandLineActivatesByDefault() {
    let action = try? TunnelControlCLIAction.parse(
      arguments: ["configs", "import", "/tmp/home.conf"])

    #expect(action == .configs(.importFile(path: "/tmp/home.conf", activate: true)))
  }
}
```

Run `swift test --filter ConfigImportActivationTests`. Expected failure: `error: extra argument 'activate' in call` on the request cases and `error: incorrect argument label in call` on `importFile`.

- [ ] **Step 2: Carry the choice on the wire**

In `Sources/CellTunnelCore/AgentControlRequest.swift`:

Change the case declaration and its doc comment:

```swift
  /// Validates and stores a config from its text, activating it only when asked. Relay
  /// start is left to the explicit start action. Storing without activating was two
  /// requests with a client-side undo between them, so a dropped connection between them
  /// left the wrong config active.
  case importConfig(name: String, text: String, activate: Bool)
```

Add `case configActivate` to `CodingKeys`, keeping the list alphabetical, so it goes first.

In `decodeRequest(kind:from:)`, replace the `.importConfig` branch:

```swift
    case .importConfig:
      return .importConfig(
        name: try container.decode(String.self, forKey: .configName),
        text: try container.decode(String.self, forKey: .configText),
        // A client that predates the field expected import to activate, so an absent
        // key has to keep meaning exactly that.
        activate: try container.decodeIfPresent(Bool.self, forKey: .configActivate) ?? true
      )
```

In `encodeRequest(_:into:)`, replace the `.importConfig` branch:

```swift
    case let .importConfig(name, text, activate):
      try container.encode(Kind.importConfig, forKey: .kind)
      try container.encode(name, forKey: .configName)
      try container.encode(text, forKey: .configText)
      try container.encode(activate, forKey: .configActivate)
```

Update the protocol requirement in the same file:

```swift
  /// Validates and stores a config, activating it only when asked, then returns the
  /// refreshed status carrying the updated library.
  func importConfig(name: String, text: String, activate: Bool) async throws
    -> TunnelDaemonStatusSnapshot
```

In `Sources/CellTunnelCore/AgentClient.swift`, update the conforming method's signature to match and pass `activate` straight into the request it builds.

- [ ] **Step 3: Have the agent honor it**

In `Apps/macOS/Agent/AgentTunnelController+Configs.swift`, change `handleImportConfig` to take the flag and only set the active id when asked:

```swift
  /// Validates and stores a config from its text, activating it only when asked, then
  /// returns the refreshed status carrying the updated library. Import resolves external
  /// text to a library id but leaves relay start to the explicit start action.
  func handleImportConfig(
    name: String, text: String, activate: Bool
  ) async -> AgentControlResponse {
```

and inside the `do` block, replace

```swift
      saved = try configStore.addDeduplicated(name: name, text: text)
      configStore.setActive(id: saved.id)
```

with

```swift
      saved = try configStore.addDeduplicated(name: name, text: text)
      if activate {
        configStore.setActive(id: saved.id)
      }
```

In `Apps/macOS/Agent/AgentTunnelController+Requests.swift`, update the dispatch arm for `.importConfig` to bind and forward the third associated value.

- [ ] **Step 4: Have the command-line tool offer it**

In `Sources/CellTunnelCore/TunnelControlCLIAction.swift`, change the case:

```swift
  case importFile(path: String, activate: Bool)
```

Replace the `import` arm of `ConfigsCommand.parse(arguments:)`:

```swift
    case "import":
      guard let path = rest.first, !path.hasPrefix("--") else {
        throw TunnelDaemonError.usage("configs import requires <path>")
      }
      let options = Array(rest.dropFirst())
      guard options.isEmpty || options == [noActivateOption] else {
        throw TunnelDaemonError.usage("configs import accepts <path> [\(noActivateOption)]")
      }
      return .importFile(path: path, activate: options.isEmpty)
```

Add the constant beside the other private constants at the top of the file:

```swift
private let noActivateOption = "--no-activate"
```

In `runConfigs(_:)`, replace the `.importFile` arm:

```swift
    case let .importFile(path, activate):
      let file = try await configImportFileLoader.load(path: path)
      let snapshot = try await client.importConfig(
        name: file.name, text: file.text, activate: activate)
      return renderConfigListing(
        configs: snapshot.configLibrary ?? [], activeID: snapshot.activeConfigID)
```

Run `swift test --filter ConfigImportActivationTests`. Expected: all five tests pass.

- [ ] **Step 5: Delete the app's two-request transaction**

In `Apps/iOS/Services/ConfigLibraryBackend.swift`, change the `importConfig(name:text:)` requirement to `importConfig(name:text:activate:)`. In `Apps/iOS/Services/AgentRelayBackend.swift`, update its implementation to forward the flag, and update its `importConfig(url:name:)` path to pass `activate: true`, which is what importing a picked file has always meant.

In `Apps/iOS/Services/RelayController+ConfigLibrary.swift`, replace `createConfig(name:text:)` in full:

```swift
    /// Creates a stored configuration from raw text without leaving it active, for the
    /// new-config flow. One request, because the agent now stores without activating;
    /// the earlier version imported and then sent a second request to undo the
    /// activation, so a dropped connection between the two left the wrong config active.
    func createConfig(name: String, text: String) {
      configLibraryLogger.notice("relay controller create config requested")
      Task {
        do {
          try await configLibraryBackend.importConfig(name: name, text: text, activate: false)
        } catch {
          configLibraryLogger.error(
            """
            relay controller create config failed \
            details=\(String(describing: error), privacy: .public) recovery=keep-state
            """
          )
        }
      }
    }
```

Update `importConfig(url:name:)` in the same file to pass through unchanged; it goes through the backend's URL path, not this one.

In `Apps/iOS/Services/RelayController.swift`, delete the pinned id and its doc comment:

```swift
    /// The active config id held across a new-config create and restore so the poll
    /// cannot momentarily surface the agent's intermediate "new config is active" state
    /// between `importConfig` and the restoring `activateConfig`. Non-nil only while a
    /// create that preserves a prior active config is in flight.
    var pinnedActiveConfigID: UUID?
```

and in `apply(_:)` replace the pinned read with the snapshot's own value:

```swift
      assign(\.activeConfigID, sample.activeConfigID)
```

deleting the comment above it that explains the pin.

- [ ] **Step 6: Build and gate**

```bash
swift test --filter ConfigImportActivationTests
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```

Expected: tests pass, every gate `ok`, exit 0.

- [ ] **Step 7: Verify both clients agree about adding a configuration**

With one configuration already active:

```bash
Products/celltunnelctl configs list
Products/celltunnelctl configs import /tmp/second.conf --no-activate
Products/celltunnelctl configs list
```

Expected: the second listing shows both configurations with `(active)` still on the first. Then use New in the Mac app's Configs card and confirm the checkmark never moves, including mid-request.

- [ ] **Step 8: Commit**

```bash
git add Sources/CellTunnelCore Tests/CellTunnelCoreTests/ConfigImportActivationTests.swift \
  Apps/macOS/Agent Apps/iOS
git commit -S -m "Store a configuration without activating it in one request" \
  -m "Adding a configuration took an import plus a second request undoing the activation the agent performed unconditionally, so a drop between the two left the wrong configuration active, and the command-line tool sent only the first request so the two clients disagreed about what adding a configuration meant." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 8: Delete the app's duplicate network probes

The app runs an egress monitor and a public-address probe on a sixty second timer, and the agent runs the identical pair on the identical interval. The app then arbitrates between the two sources on every poll and calls `InterfaceAddressLookup.allAddresses` once per second to fill the interface rows. Everything it computes is already on the snapshot or can be, so the second set of probes is duplicated work whose only other effect is that the app and the agent can report different addresses for the same machine.

**Files:**
- Modify: `Sources/CellTunnelCore/InterfaceAddressLookup.swift`
- Modify: `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`
- Modify: `Sources/CellTunnelRelay/RelayRuntime.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Control.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Delete: `Apps/iOS/Services/DeviceEgressProbe.swift`
- Modify: `Apps/iOS/CellTunnelPhoneApp.swift`
- Modify: `Apps/iOS/Testing/UITestFixture.swift`
- Modify: `Apps/iOS/Views/RelayStatusScreen.swift`
- Modify: `Apps/iOS/Views/MacStatusScreen.swift`
- Modify: `Apps/iOS/Views/PhoneContentView.swift`
- Modify: `Apps/iOS/Views/SetupScreen.swift`
- Modify: `Apps/iOS/Views/EnableTunnelScreen.swift`
- Test: `Tests/CellTunnelCoreTests/InterfaceAddressListWireTests.swift`

**Interfaces:**
- Consumes: `TunnelDaemonStatusSnapshot` as Task 6 left it.
- Produces:
  - `InterfaceAddressList` gains `Codable` conformance.
  - `TunnelDaemonStatusSnapshot.deviceInterfaceAddresses: InterfaceAddressList?`, last initializer parameter, defaulting to `nil`.
  - `RelayController.init` loses its `deviceProbe:` parameter on both platforms. `RelayController.interfaceAddresses`, `cellularPath`, and `devicePublicAddresses` keep their names and types; only their source changes.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/InterfaceAddressListWireTests.swift`:

```swift
//
//  InterfaceAddressListWireTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - InterfaceAddressListWireTests

/// Covers the egress interface's addresses travelling on the snapshot. The app read
/// them itself, once per poll, from a system call it made on the render path.
struct InterfaceAddressListWireTests {
  @Test func travelsOnTheWire() {
    let addresses = InterfaceAddressList(ipv4: ["10.0.0.2"], ipv6: ["fd00::2"])
    let snapshot = TunnelDaemonStatusSnapshot(deviceInterfaceAddresses: addresses)
    let encoded = try? JSONEncoder().encode(snapshot)
    let decoded = encoded.flatMap {
      try? JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: $0)
    }

    #expect(decoded?.deviceInterfaceAddresses == addresses)
  }

  @Test func absentFromAnOlderProducer() {
    #expect(TunnelDaemonStatusSnapshot().deviceInterfaceAddresses == nil)
  }
}
```

Run `swift test --filter InterfaceAddressListWireTests`. Expected failure: `error: extra argument 'deviceInterfaceAddresses' in call`.

- [ ] **Step 2: Put the addresses on the wire**

In `Sources/CellTunnelCore/InterfaceAddressLookup.swift`, change the declaration to

```swift
public struct InterfaceAddressList: Codable, Sendable, Equatable {
```

In `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, add after `situation`:

```swift
  /// Every address on the producer's egress interface, read by the producer rather than
  /// by each client. `nil` from a producer that predates the field.
  public var deviceInterfaceAddresses: InterfaceAddressList?
```

Add `deviceInterfaceAddresses: InterfaceAddressList? = nil` as the last `init` parameter with its assignment.

Run `swift test --filter InterfaceAddressListWireTests`. Expected: both tests pass.

- [ ] **Step 3: Fill it from both producers**

In `Apps/macOS/Agent/AgentTunnelController+Control.swift`, inside `augmented(_:profileState:)`, immediately after the line that sets `merged.cellularPath`, add:

```swift
    // Read here rather than by each client, so the interface rows show the same
    // addresses the agent measured its own egress from.
    merged.deviceInterfaceAddresses = InterfaceAddressLookup.allAddresses(
      forInterface: merged.cellularPath?.interfaceName ?? "")
```

In `Sources/CellTunnelRelay/RelayRuntime.swift`, inside `statusSnapshot()`, after the `snapshot.situation` assignment added in Task 6, add:

```swift
    snapshot.deviceInterfaceAddresses = InterfaceAddressLookup.allAddresses(
      forInterface: snapshot.cellularPath?.interfaceName ?? "")
```

- [ ] **Step 4: Delete the app's probe and its arbitration**

In `Apps/iOS/Services/RelayController.swift`:

Delete the stored probe and the four probe-versus-backend fields with their comment:

```swift
  private let deviceProbe: DeviceEgressProbe?
```

```swift
  // The latest device egress and public address from the backend snapshot and from
  // the app's own probe, kept apart so one recompute picks the right source: the
  // backend's values while the relay carries the device's traffic, the probe's
  // otherwise.
  private var backendCellularPath = CellularPathSnapshot()
  private var backendDevicePublicAddresses = AddressPair.empty
  private var probeCellularPath = CellularPathSnapshot()
  private var probeDevicePublicAddresses = AddressPair.empty
```

Delete the `deviceProbe:` parameter from both `init` overloads and both assignments. Delete `startDeviceProbe()`, `applyProbe(cellularPath:publicAddresses:)`, and `recomputeDeviceValues()` in full, along with their comments. In `start()`, delete the `startDeviceProbe()` call.

In `apply(_:)`, replace the three assignments that fed the deleted fields:

```swift
    assign(\.backendCellularPath, sample.cellularPath)
```
becomes
```swift
    assign(\.cellularPath, sample.cellularPath)
```

```swift
    assign(\.backendDevicePublicAddresses, sample.devicePublicAddresses)
```
becomes
```swift
    assign(\.devicePublicAddresses, sample.devicePublicAddresses)
```

and delete the `recomputeDeviceValues()` call, replacing it with:

```swift
    assign(\.interfaceAddresses, sample.deviceInterfaceAddresses)
```

Add the field to `RelayStatusSample` beside `devicePublicAddresses`:

```swift
  /// Every address on the producer's egress interface. The app used to read these
  /// itself, once per poll, rather than take the producer's own reading.
  var deviceInterfaceAddresses: InterfaceAddressList
```

and assign it in `init(snapshot:)`:

```swift
    deviceInterfaceAddresses = snapshot.deviceInterfaceAddresses ?? .empty
```

- [ ] **Step 5: Delete the probe file and every construction of it**

Delete `Apps/iOS/Services/DeviceEgressProbe.swift`. Remove the `deviceProbe:` argument from every `RelayController(...)` call that passes one, across the eight call sites listed in Task 3 Step 8.

- [ ] **Step 6: Build and gate**

```bash
swift test --filter InterfaceAddressListWireTests
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```

Expected: tests pass, every gate `ok`, exit 0.

- [ ] **Step 7: Verify the rows still fill and now match the agent**

Open the Mac app with the agent running and routing off, and compare:

```bash
Products/celltunnelctl status 2>&1 | grep -E 'device_public|interface'
```

Expected: the `Device / Public` and `Interface` rows in the app show the same values the agent reports. Before this change the app could show its own probe's answer while the agent showed a different one. If the rows are empty while the agent is reachable, the agent is not filling `deviceInterfaceAddresses`, not the app failing to render it.

- [ ] **Step 8: Commit**

```bash
git add Sources/CellTunnelCore/InterfaceAddressLookup.swift \
  Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift \
  Tests/CellTunnelCoreTests/InterfaceAddressListWireTests.swift \
  Sources/CellTunnelRelay/RelayRuntime.swift \
  Apps/macOS/Agent/AgentTunnelController+Control.swift \
  Apps/iOS
git commit -S -m "Read the device's own network facts once, in the daemon" \
  -m "The app ran an egress monitor and a public-address probe the agent already ran on the same interval, arbitrated between the two results on every poll, and called the interface address lookup once a second, so the two could report different addresses for the same machine." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

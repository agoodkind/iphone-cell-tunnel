# Daemon Pushes State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the app's once-per-second status poll with a subscription, so the agent sends a fresh snapshot when something changes and the app stops asking.

**Architecture:** The control transport is strictly request and reply today. The agent keeps each client's connection alive after replying but keeps no reference to it, so it cannot address a client outside a reply. The client installs no handler for unsolicited messages. This plan adds a peer registry on the agent side and an incoming-message handler on the client side, then has the agent send the snapshot to every subscriber whenever it changes. The poll loop is removed last, once the push path is proven.

**Tech Stack:** Swift 6, libxpc via `XPCSession` and `xpc_connection_t`, Swift Testing, SwiftPM for `Sources/CellTunnelCore`, Tuist for the app targets.

## Global Constraints

- `AgentClient.send` and `AgentClient.transmit` are synchronous actor methods and `session.sendSync` blocks for the whole round trip, so every request serializes on the actor. A subscription must never be a held-open request: it would block every other caller. The agent pushes on its own initiative instead.
- `AgentControlRequest` is a hand-written `Codable` with a `kind` discriminator. Every new case needs three edits in lockstep: a `Kind` entry, a `decodeRequest` arm, and an `encodeRequest` arm, all in `Sources/CellTunnelCore/AgentControlRequest.swift`. The `handle(request:)` switch in `Apps/macOS/Agent/AgentTunnelController+Requests.swift` is exhaustive with no `default`, so a new case forces a compile error there too.
- The wire version is `agentControlWireVersion = 2` at `Sources/CellTunnelCore/AgentControlRequest.swift:11`, stamped on both the envelope and the response. Adding a push message is a wire change; raise it to 3 and keep the constant the single source.
- The payload key is `agentControlPayloadKey`, defined at `Sources/CellTunnelCore/AgentControlXPC.swift:20`. Never hardcode the literal.
- Every snapshot field already has a default in the memberwise init, so adding an optional field is source-compatible with existing call sites.
- Tests live in `Tests/CellTunnelCoreTests` and use Swift Testing, not XCTest.
- Enum cases must be declared in alphabetical order; `lint-swiftlint` enforces it.
- A new file in `Sources/` must be reachable from a SwiftPM target or `lint-deadcode` fails it.
- Build and gate with the repo's dev tool, not `swift build`:
  `SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic swift Tools/cell-tunnel-dev.swift build mac Debug`
- Run package tests with `swift test --filter <SuiteName>` from the repo root.

---

### Task 1: Give the agent a way to address its connected clients

The agent accepts a peer connection at `Apps/macOS/Agent/AgentSessionListener.swift:83` and keeps it alive, but the handle is captured only inside the per-message `ReplyChannel` at line 96. The listener retains only `listenerConnection` at line 26. Without a registry the agent cannot send anything a client did not ask for.

This task adds the registry and its tests. It changes no behavior on its own.

**Files:**
- Create: `Sources/CellTunnelCore/SubscriberRegistry.swift`
- Test: `Tests/CellTunnelCoreTests/SubscriberRegistryTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `SubscriberRegistry`, a `public final class` conforming to `Sendable`, holding `Sendable` send closures keyed by a token. API: `public init()`, `public func add(_ send: @escaping @Sendable (Data) -> Void) -> UUID`, `public func remove(_ token: UUID)`, `public func broadcast(_ payload: Data)`, and `public var count: Int`. Task 2 registers one closure per connected peer and calls `broadcast` on every state change.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/SubscriberRegistryTests.swift`:

```swift
//
//  SubscriberRegistryTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Synchronization
import Testing

@testable import CellTunnelCore

@Suite("Subscriber registry")
struct SubscriberRegistryTests {
  @Test("a broadcast reaches every registered subscriber")
  func broadcastReachesEveryone() {
    let registry = SubscriberRegistry()
    let received = Mutex<[String]>([])
    _ = registry.add { data in
      received.withLock { $0.append("first:" + String(decoding: data, as: UTF8.self)) }
    }
    _ = registry.add { data in
      received.withLock { $0.append("second:" + String(decoding: data, as: UTF8.self)) }
    }

    registry.broadcast(Data("hello".utf8))

    let seen = received.withLock { $0.sorted() }
    #expect(seen == ["first:hello", "second:hello"])
  }

  /// A client that goes away must stop receiving, or the agent sends into a dead
  /// connection on every state change for the rest of its life.
  @Test("a removed subscriber stops receiving")
  func removedSubscriberStopsReceiving() {
    let registry = SubscriberRegistry()
    let count = Mutex(0)
    let token = registry.add { _ in
      count.withLock { $0 += 1 }
    }

    registry.broadcast(Data("one".utf8))
    registry.remove(token)
    registry.broadcast(Data("two".utf8))

    #expect(count.withLock { $0 } == 1)
  }

  @Test("the count reflects what is registered")
  func countReflectsRegistrations() {
    let registry = SubscriberRegistry()
    #expect(registry.count == 0)
    let first = registry.add { _ in }
    _ = registry.add { _ in }
    #expect(registry.count == 2)
    registry.remove(first)
    #expect(registry.count == 1)
  }

  /// Removing something already gone is normal, because a disconnect and an
  /// explicit unsubscribe can both arrive for the same client.
  @Test("removing an unknown token is harmless")
  func removingUnknownTokenIsHarmless() {
    let registry = SubscriberRegistry()
    registry.remove(UUID())
    #expect(registry.count == 0)
  }

  @Test("a broadcast with no subscribers does nothing")
  func broadcastWithNoSubscribersDoesNothing() {
    let registry = SubscriberRegistry()
    registry.broadcast(Data("ignored".utf8))
    #expect(registry.count == 0)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SubscriberRegistryTests`
Expected: FAIL to compile, `cannot find 'SubscriberRegistry' in scope`.

- [ ] **Step 3: Write the registry**

Create `Sources/CellTunnelCore/SubscriberRegistry.swift`:

```swift
//
//  SubscriberRegistry.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Synchronization

// MARK: - SubscriberRegistry

/// Holds the way to reach each client that asked to be told about changes.
///
/// The agent answers requests on connections it does not otherwise keep track
/// of, so without this it can only ever speak when spoken to. That forces every
/// client to ask repeatedly, which is why the app polls once a second and why a
/// change is invisible until the next tick.
///
/// Each entry is a closure rather than a connection handle, so the registry
/// stays free of the transport and can be tested without one.
public final class SubscriberRegistry: Sendable {
  private let subscribers = Mutex<[UUID: @Sendable (Data) -> Void]>([:])

  public init() {}

  /// How many clients are currently listening.
  public var count: Int {
    subscribers.withLock { $0.count }
  }

  /// Registers a way to reach one client, returning the token that removes it.
  public func add(_ send: @escaping @Sendable (Data) -> Void) -> UUID {
    let token = UUID()
    subscribers.withLock { $0[token] = send }
    return token
  }

  /// Stops reaching one client. Removing a token that is already gone is normal,
  /// because a dropped connection and an explicit unsubscribe can both arrive.
  public func remove(_ token: UUID) {
    subscribers.withLock { $0[token] = nil }
  }

  /// Sends one payload to every listening client.
  ///
  /// The sends run outside the lock so a slow or blocked client cannot hold up
  /// the state change that triggered the broadcast.
  public func broadcast(_ payload: Data) {
    let targets = subscribers.withLock { Array($0.values) }
    for send in targets {
      send(payload)
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SubscriberRegistryTests`
Expected: PASS, 5 tests.

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
git add Sources/CellTunnelCore/SubscriberRegistry.swift Tests/CellTunnelCoreTests/SubscriberRegistryTests.swift
git commit -S -m "Hold a way to reach each listening client" \
  -m "The agent answered requests on connections it kept no reference to, so it could only speak when spoken to and every client had to ask repeatedly." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 2: Send the snapshot to subscribed clients when it changes

The agent produces a fresh status snapshot on every mutating request and on every VPN, route, and link transition, and then drops it once the reply is written. A client that was not the one asking learns nothing, so the only way to see a change is to ask again. This task makes the agent hand that snapshot to every client that asked to be told.

The registry from Task 1 is created once in the composition root and given to both the listener, which knows the peers, and the controller, which knows the state. A `subscribe` request registers the asking peer and replies with the snapshot as it stands, so the client has a baseline before the first push.

The counters are the one part of the snapshot with no discrete moment to announce: they advance with every packet. A repeating push covers them, but only while a client is subscribed and the relay is actually hosted, so an idle Mac app costs nothing at all rather than one round trip per second.

**Files:**
- Modify: `Sources/CellTunnelCore/AgentControlRequest.swift`
- Modify: `Apps/macOS/Agent/AgentSessionListener.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Requests.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Manager.swift`
- Modify: `Apps/macOS/Agent/AgentTunnelController+Control.swift`
- Modify: `Apps/macOS/Agent/main.swift`
- Create: `Apps/macOS/Agent/AgentTunnelController+Push.swift`
- Test: `Tests/CellTunnelCoreTests/AgentControlSubscribeTests.swift`

**Interfaces:**
- Consumes: `SubscriberRegistry` from Task 1, exactly as built there: `public init()`, `public func add(_ send: @escaping @Sendable (Data) -> Void) -> UUID`, `public func remove(_ token: UUID)`, `public func broadcast(_ payload: Data)`, `public var count: Int`.
- Produces, for Task 3 to consume: the wire contract. `AgentControlRequest.subscribe` is a new case with no associated values, encoded under the existing `kind` key as the string `subscribe`. The agent replies to it with a normal `AgentControlResponse` carrying `status`. Every later push is a JSON `AgentControlResponse` carrying `status`, set as data under `agentControlPayloadKey` on a fresh xpc dictionary sent to the peer, never a reply dictionary. A push is distinguishable from a reply by arrival alone: replies come back from `sendSync`, pushes arrive at the session's incoming-message handler, so no marker field is needed. `agentControlWireVersion` becomes `3`. A subscription lasts for the life of the connection: there is no unsubscribe message, and cancelling the client's session is what ends it.
- Also produces: `public var mutatesState: Bool` on `AgentControlRequest`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/AgentControlSubscribeTests.swift`:

```swift
//
//  AgentControlSubscribeTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import CellTunnelCore

@Suite("Agent control subscribe request")
struct AgentControlSubscribeTests {
  /// The request enum is hand-written, so a case added to the enum without both
  /// coding arms encodes or decodes into something else. A round trip is the only
  /// thing that catches that.
  @Test("a subscribe request survives the round trip")
  func subscribeSurvivesRoundTrip() throws {
    let encoded = try JSONEncoder().encode(AgentControlEnvelope(request: .subscribe))
    let decoded = try JSONDecoder().decode(AgentControlEnvelope.self, from: encoded)

    guard case .subscribe = decoded.request else {
      Issue.record("decoded \(decoded.request) instead of subscribe")
      return
    }
    #expect(decoded.version == agentControlWireVersion)
  }

  @Test("subscribe travels under the kind discriminator")
  func subscribeTravelsUnderKind() throws {
    let encoded = try JSONEncoder().encode(AgentControlEnvelope(request: .subscribe))
    let text = String(decoding: encoded, as: UTF8.self)

    #expect(text.contains("\"kind\":\"subscribe\""))
  }

  /// Broadcasting after a read would push a snapshot the asking client already has
  /// and would make every status request cost a second status read.
  @Test("reads do not count as state changes")
  func readsDoNotCountAsStateChanges() {
    #expect(AgentControlRequest.status.mutatesState == false)
    #expect(AgentControlRequest.subscribe.mutatesState == false)
    #expect(AgentControlRequest.check.mutatesState == false)
    #expect(AgentControlRequest.listRelayServices.mutatesState == false)
    #expect(AgentControlRequest.getConfigText(id: UUID()).mutatesState == false)
  }

  @Test("changes count as state changes")
  func changesCountAsStateChanges() {
    #expect(AgentControlRequest.setRoutingEnabled(enabled: true).mutatesState)
    #expect(AgentControlRequest.reset.mutatesState)
    #expect(AgentControlRequest.deleteConfig(id: UUID()).mutatesState)
    #expect(AgentControlRequest.selectEgressPeer(peerID: "peer").mutatesState)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AgentControlSubscribeTests`
Expected: FAIL to compile, `type 'AgentControlRequest' has no member 'subscribe'`.

- [ ] **Step 3: Add the subscribe case and the change classifier**

In `Sources/CellTunnelCore/AgentControlRequest.swift`, raise the wire version at line 11:

```swift
public let agentControlWireVersion = 3
```

Add the case to the public enum, between `stopTunnel` and `validateConfig`:

```swift
  case stopTunnel
  /// Asks the agent to send a fresh snapshot on this connection whenever the state
  /// changes. The reply carries the snapshot as it stands, so the client has a
  /// baseline before the first push. It lasts for the life of the connection.
  case subscribe
  /// Validates WireGuard configuration text without changing tunnel state.
  case validateConfig(text: String)
```

Add the matching `Kind` entry, between `stopTunnel` and `validateConfig`:

```swift
    case stopTunnel
    case subscribe
    case validateConfig
```

Add the `decodeRequest` arm, between the `stopTunnel` and `validateConfig` arms:

```swift
    case .stopTunnel:
      return .stopTunnel
    case .subscribe:
      return .subscribe
    case .validateConfig:
      return .validateConfig(text: try container.decode(String.self, forKey: .configText))
```

Add the `encodeRequest` arm, between the `stopTunnel` and `validateConfig` arms:

```swift
    case .stopTunnel: try encodeKind(.stopTunnel, into: &container)
    case .subscribe: try encodeKind(.subscribe, into: &container)
    case .validateConfig(let text):
```

Add the classifier as the last member of the enum, after `encodeKind`:

```swift
  /// Whether handling this request can change what a status snapshot reports, which
  /// is what decides whether subscribers hear about it afterwards.
  ///
  /// The reads are listed and everything else is a change, so a case added later is
  /// treated as a change until someone says otherwise. Pushing a snapshot nobody
  /// needed is wasteful; failing to push one leaves every screen stale.
  public var mutatesState: Bool {
    switch self {
    case .check, .getConfigText, .listRelayServices, .status, .subscribe:
      return false
    default:
      return true
    }
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AgentControlSubscribeTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Hold the registry on the controller**

In `Apps/macOS/Agent/AgentTunnelController.swift`, add the two stored properties and the init parameter. Put the properties after `configDriftMessage` at line 48:

```swift
  var configDriftMessage: String?

  /// The clients listening for status pushes. Shared with `AgentSessionListener`,
  /// which registers a peer when it subscribes, so the side that knows the state and
  /// the side that knows the connections work from one list.
  nonisolated let subscribers: SubscriberRegistry
  /// The repeating push that carries the byte counters while the relay is hosted, or
  /// nil while nothing is listening. See `startStatusPushTimer`.
  var statusPushTimer: DispatchSourceTimer?
```

Extend the init at lines 93 to 101:

```swift
  init(
    relayBridge: AgentRelayBridge,
    relayBrowser: RelayDeviceBrowser,
    configStore: TunnelConfigStore = AgentConfigStore(),
    subscribers: SubscriberRegistry = SubscriberRegistry()
  ) {
    self.relayBridge = relayBridge
    self.relayBrowser = relayBrowser
    self.configStore = configStore
    self.subscribers = subscribers
  }
```

- [ ] **Step 6: Write the broadcast**

Create `Apps/macOS/Agent/AgentTunnelController+Push.swift`:

```swift
//
//  AgentTunnelController+Push.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Dispatch
import Foundation

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)
private let statusPushIntervalSeconds = 1

// MARK: - Status pushes

extension AgentTunnelController {
  /// Sends the current status to every subscribed client.
  ///
  /// Building the snapshot means reading the running tunnel, so this returns early
  /// when nobody is listening rather than paying for a snapshot with no reader.
  func broadcastStatus() async {
    guard subscribers.count > 0 else {
      return
    }
    let response = await handleStatus()
    let payload: Data
    do {
      payload = try JSONEncoder().encode(response)
    } catch {
      logger.error(
        """
        agent status push encode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=skip-push
        """
      )
      return
    }
    subscribers.broadcast(payload)
    logger.debug(
      """
      agent status pushed subscribers=\(self.subscribers.count, privacy: .public) \
      bytes=\(payload.count, privacy: .public)
      """
    )
  }

  /// Starts the repeating push that carries the byte counters.
  ///
  /// Everything else in the snapshot changes at a moment some handler or observer
  /// can announce, but the counters advance with every packet and nothing announces
  /// them. The timer stops itself once the last client leaves and pushes nothing
  /// while the relay is not hosted, so an idle Mac app costs no traffic at all.
  func startStatusPushTimer() {
    guard statusPushTimer == nil else {
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + .seconds(statusPushIntervalSeconds),
      repeating: .seconds(statusPushIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      Task { await self?.pushCountersTick() }
    }
    timer.resume()
    statusPushTimer = timer
    logger.notice(
      """
      agent status push timer started \
      intervalSeconds=\(statusPushIntervalSeconds, privacy: .public)
      """
    )
  }

  private func pushCountersTick() async {
    guard subscribers.count > 0 else {
      statusPushTimer?.cancel()
      statusPushTimer = nil
      logger.notice("agent status push timer stopped reason=no-subscribers")
      return
    }
    guard relayHosted else {
      return
    }
    await broadcastStatus()
  }
}
```

- [ ] **Step 7: Register a peer when it subscribes**

In `Apps/macOS/Agent/AgentSessionListener.swift`, take the registry and keep one subscription object per peer. Replace the stored properties and init at lines 25 to 30:

```swift
  private let controller: AgentTunnelController
  private let subscribers: SubscriberRegistry
  private var listenerConnection: xpc_connection_t?

  init(controller: AgentTunnelController, subscribers: SubscriberRegistry) {
    self.controller = controller
    self.subscribers = subscribers
  }
```

Replace `handleIncomingPeer` at lines 70 to 85:

```swift
  private func handleIncomingPeer(_ peer: xpc_object_t) {
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
      logger.error(
        """
        agent session listener received non-connection event \
        recovery=ignore
        """
      )
      return
    }
    // The subscription is created with the peer and held by the peer's own event
    // handler, so it lives exactly as long as the connection does. An error event is
    // the only notice that a client is gone, so it is also the only chance to stop
    // sending into a dead connection.
    let subscription = PeerSubscription(peer: peer, registry: subscribers)
    xpc_connection_set_event_handler(peer) { [weak self] message in
      guard xpc_get_type(message) != XPC_TYPE_ERROR else {
        subscription.end()
        logger.notice("agent session listener peer connection ended")
        return
      }
      self?.handleIncomingMessage(message, on: peer, subscription: subscription)
    }
    xpc_connection_resume(peer)
    logger.notice("agent session listener accepted inbound session")
  }
```

Change the signature of `handleIncomingMessage` at line 87 and register on a subscribe request. The registration happens here, before the controller call, so a snapshot pushed while the reply is still being built still reaches the new subscriber:

```swift
  private func handleIncomingMessage(
    _ message: xpc_object_t,
    on peer: xpc_connection_t,
    subscription: PeerSubscription
  ) {
```

Then, in the same method, insert the registration between the decode and the controller call, replacing the two lines at 123 and 124:

```swift
    if case .subscribe = request {
      subscription.begin()
    }
    let handlingController = self.controller
    Task {
```

Add `PeerSubscription` at the end of the file, after `ReplyChannel`:

```swift
// MARK: - PeerSubscription

/// One client's place in the push registry, for the life of its connection.
///
/// The registry holds plain send closures so it can stay free of the transport, so
/// the non-Sendable peer handle is boxed here and only the send is published. The
/// token is kept so the object that registered the client is the one that drops it
/// when the connection reports it is gone.
private final class PeerSubscription: @unchecked Sendable {
  private let peer: xpc_connection_t
  private let registry: SubscriberRegistry
  private let token = Mutex<UUID?>(nil)

  init(peer: xpc_connection_t, registry: SubscriberRegistry) {
    self.peer = peer
    self.registry = registry
  }

  /// Registers this peer once. A client that subscribes twice on one connection
  /// stays a single subscriber, so a repeat cannot double every push it receives.
  func begin() {
    token.withLock { current in
      guard current == nil else {
        return
      }
      current = registry.add { [weak self] payload in
        self?.sendPush(payload)
      }
      logger.notice("agent session listener registered subscriber")
    }
  }

  func end() {
    let removed = token.withLock { current -> UUID? in
      let previous = current
      current = nil
      return previous
    }
    guard let removed else {
      return
    }
    registry.remove(removed)
    logger.notice("agent session listener removed subscriber")
  }

  // A push answers no request, so it is a fresh dictionary sent on the peer.
  // `xpc_dictionary_create_reply` needs an inbound message to reply to, and there is
  // none here.
  private func sendPush(_ payload: Data) {
    let message = xpc_dictionary_create_empty()
    payload.withUnsafeBytes { rawBuffer in
      xpc_dictionary_set_data(
        message, agentControlPayloadKey, rawBuffer.baseAddress, rawBuffer.count
      )
    }
    xpc_connection_send_message(peer, message)
  }
}
```

Add `import Synchronization` to the file's imports, after `import Foundation`, for the `Mutex`.

- [ ] **Step 8: Broadcast after every change**

In `Apps/macOS/Agent/AgentTunnelController+Requests.swift`, wrap the existing switch so one place decides whether to tell subscribers. Replace the opening of `handle(request:)` at lines 21 and 22:

```swift
  /// Answers one request and, when it changed something, tells every subscriber.
  ///
  /// The push runs after the reply is handed back rather than before it, so the
  /// client waiting on the round trip does not also wait for the extra status read
  /// the broadcast performs. The two can arrive in either order and carry the same
  /// state, which the app applies idempotently.
  func handle(request: AgentControlRequest) async -> AgentControlResponse {
    let response = await respond(to: request)
    if request.mutatesState {
      Task { await self.broadcastStatus() }
    }
    return response
  }

  private func respond(to request: AgentControlRequest) async -> AgentControlResponse {
    switch request {
```

Add the `subscribe` arm to that switch, between the `stopTunnel` and `validateConfig` arms:

```swift
    case .stopTunnel:
      return await handleSetRoutingEnabled(false)
    case .subscribe:
      startStatusPushTimer()
      return await handleStatus()
    case .validateConfig(let text):
      return await handleValidateConfig(text: text)
```

In `Apps/macOS/Agent/AgentTunnelController+Manager.swift`, push when the system changes the tunnel underneath the app. Replace `recordStatus` at lines 175 to 180:

```swift
  private func recordStatus(_ status: NEVPNStatus) async {
    logger.notice(
      "agent observed vpn status=\(self.statusDescription(status), privacy: .public)"
    )
    await reconcileRoutingIntent(with: status)
    // Nothing asked for this change, so nothing else would tell the screens about it.
    await broadcastStatus()
  }
```

In `Apps/macOS/Agent/AgentTunnelController+Control.swift`, push when the phone link flips. Add the broadcast as the last line of `handlePhoneLink(up:)`, after the `if up` block ending at line 473:

```swift
    } else {
      // Debounce the withdrawal so a sub-grace AWDL blip does not flip the UI to
      // passthrough. The peer name is not cleared here; it follows the control
      // link and clears only when that link drops.
      peerLinks.withLock { $0 = nil }
      scheduleRouteWithdraw(generation: routeWithdrawGeneration)
    }
    await broadcastStatus()
  }
```

- [ ] **Step 9: Build one registry in the composition root**

In `Apps/macOS/Agent/main.swift`, hold the registry on the runtime and give it to both sides. Replace the stored properties and init at lines 31 to 36:

```swift
  private let controller: AgentTunnelController
  private let subscribers: SubscriberRegistry
  private var sessionListener: AgentSessionListener?

  init(controller: AgentTunnelController, subscribers: SubscriberRegistry) {
    self.controller = controller
    self.subscribers = subscribers
  }
```

Replace the listener construction at line 46:

```swift
    let listener = AgentSessionListener(controller: controller, subscribers: subscribers)
```

Replace the two graph lines at 139 and 140:

```swift
  let subscribers = SubscriberRegistry()
  let controller = AgentTunnelController(
    relayBridge: relayBridge,
    relayBrowser: relayBrowser,
    subscribers: subscribers
  )
  let agentRuntime = AgentRuntime(controller: controller, subscribers: subscribers)
```

- [ ] **Step 10: Run the full gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

The agent side cannot be unit tested here: `AgentSessionListener` and `AgentTunnelController` live in the Tuist agent target, which has no test bundle, and the push path needs a live mach service. Nothing pushes yet either, because no client subscribes until Task 3. The gate is the check for this task, and the live check happens in Task 4.

- [ ] **Step 11: Commit**

```bash
git add Sources/CellTunnelCore/AgentControlRequest.swift \
  Apps/macOS/Agent/AgentSessionListener.swift \
  Apps/macOS/Agent/AgentTunnelController.swift \
  Apps/macOS/Agent/AgentTunnelController+Requests.swift \
  Apps/macOS/Agent/AgentTunnelController+Manager.swift \
  Apps/macOS/Agent/AgentTunnelController+Control.swift \
  Apps/macOS/Agent/AgentTunnelController+Push.swift \
  Apps/macOS/Agent/main.swift \
  Tests/CellTunnelCoreTests/AgentControlSubscribeTests.swift
git commit -S -m "Push the status snapshot to subscribed clients" \
  -m "The agent built a fresh snapshot on every change and then dropped it once the reply was written, so a client that was not the one asking could only learn about the change by asking again." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 3: Let the control client receive what it did not ask for

`AgentClient` opens its session with `XPCSession(machService:)` and installs no incoming-message handler, so anything the agent sends outside a reply is discarded by the transport before any code sees it. The agent now pushes snapshots and nothing receives them.

The client also cannot hold a request open to wait for one. `send` and `transmit` are synchronous actor methods and `sendSync` blocks for the whole round trip, so a held-open request would block every other caller on the actor. The subscription is therefore a short request that returns immediately, and the pushes arrive separately on the session's incoming-message handler.

That handler runs on a libxpc queue, not the main actor and not the client actor. It hands the decoded snapshot to a plain `Sendable` closure the caller supplied. Reaching the main actor is the caller's job and happens one layer up: in Task 4 the Mac backend's closure yields into an `AsyncStream`, and the controller's `for await` loop, which is `@MainActor`, is what touches the published state. No `@MainActor` hop happens inside `CellTunnelCore`.

**Files:**
- Create: `Sources/CellTunnelCore/AgentPushDelivery.swift`
- Modify: `Sources/CellTunnelCore/AgentClient.swift`
- Test: `Tests/CellTunnelCoreTests/AgentPushDeliveryTests.swift`

**Interfaces:**
- Consumes from Task 2: `AgentControlRequest.subscribe`, whose reply carries `status`, and the pushes that follow, each a JSON `AgentControlResponse` carrying `status` under `agentControlPayloadKey`.
- Produces, for Task 4 to consume: on the `public actor AgentClient`, `public func subscribe(onSnapshot: @escaping @Sendable (TunnelDaemonStatusSnapshot) -> Void, onDisconnect: @escaping @Sendable () -> Void) async throws -> TunnelDaemonStatusSnapshot`. It returns the current snapshot, calls `onSnapshot` for every later push, and calls `onDisconnect` exactly once when the session ends, whichever side ended it. Both closures run off the main actor. `public func shutdown()` already exists and ends the subscription, which also reports the disconnect.
- Also produces: `AgentPushDelivery`, a `public final class` conforming to `Sendable`, holding the two closures behind a `Mutex`. API: `public init()`, `public func setHandlers(onSnapshot:onDisconnect:)`, `public func clearHandlers()`, `public func deliver(payload: Data?)`, `public func reportDisconnected()`.
- Not added to `TunnelControlClientProtocol`. That protocol is implemented by test doubles such as `Tests/CellTunnelCoreTests/SmokeTunnelControlClient.swift` which have no transport to push over, and subscribing is a property of this one transport rather than of the control surface.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/AgentPushDeliveryTests.swift`:

```swift
//
//  AgentPushDeliveryTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Synchronization
import Testing

@testable import CellTunnelCore

@Suite("Agent push delivery")
struct AgentPushDeliveryTests {
  private func encodedPush(running: Bool) throws -> Data {
    let snapshot = TunnelDaemonStatusSnapshot(running: running)
    return try JSONEncoder().encode(AgentControlResponse(status: snapshot))
  }

  @Test("a pushed payload reaches the consumer as a snapshot")
  func pushedPayloadReachesConsumer() throws {
    let delivery = AgentPushDelivery()
    let received = Mutex<[Bool]>([])
    delivery.setHandlers(
      onSnapshot: { snapshot in
        received.withLock { $0.append(snapshot.running) }
      },
      onDisconnect: {}
    )

    delivery.deliver(payload: try encodedPush(running: true))
    delivery.deliver(payload: try encodedPush(running: false))

    #expect(received.withLock { $0 } == [true, false])
  }

  /// The transport hands over whatever arrived, so a message with no payload and a
  /// payload that is not a response both reach here. Neither is a snapshot, and
  /// neither should reach the screens.
  @Test("a payload that carries no snapshot is ignored")
  func payloadWithoutSnapshotIsIgnored() throws {
    let delivery = AgentPushDelivery()
    let count = Mutex(0)
    delivery.setHandlers(
      onSnapshot: { _ in
        count.withLock { $0 += 1 }
      },
      onDisconnect: {}
    )

    delivery.deliver(payload: nil)
    delivery.deliver(payload: Data("not json".utf8))
    delivery.deliver(payload: try JSONEncoder().encode(AgentControlResponse()))

    #expect(count.withLock { $0 } == 0)
  }

  /// The session can be cancelled locally and reported gone by the peer for the same
  /// disconnect, and a consumer that hears it twice would tear down a subscription it
  /// had already replaced.
  @Test("a disconnect is reported once")
  func disconnectIsReportedOnce() {
    let delivery = AgentPushDelivery()
    let count = Mutex(0)
    delivery.setHandlers(
      onSnapshot: { _ in },
      onDisconnect: {
        count.withLock { $0 += 1 }
      }
    )

    delivery.reportDisconnected()
    delivery.reportDisconnected()

    #expect(count.withLock { $0 } == 1)
  }

  @Test("a snapshot after a disconnect is dropped")
  func snapshotAfterDisconnectIsDropped() throws {
    let delivery = AgentPushDelivery()
    let count = Mutex(0)
    delivery.setHandlers(
      onSnapshot: { _ in
        count.withLock { $0 += 1 }
      },
      onDisconnect: {}
    )

    delivery.reportDisconnected()
    delivery.deliver(payload: try encodedPush(running: true))

    #expect(count.withLock { $0 } == 0)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AgentPushDeliveryTests`
Expected: FAIL to compile, `cannot find 'AgentPushDelivery' in scope`.

- [ ] **Step 3: Write the delivery**

Create `Sources/CellTunnelCore/AgentPushDelivery.swift`:

```swift
//
//  AgentPushDelivery.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Synchronization

// MARK: - AgentPushDelivery

/// Carries what the agent sends on its own initiative back to whoever asked for it.
///
/// The transport hands a pushed message to a `@Sendable` closure on a libxpc queue,
/// with no reference to the actor that opened the session and no way to await
/// anything. Holding the consumer's closures behind a lock here is what lets that
/// queue reach the consumer, and keeping the decode here rather than in the handler
/// means the behavior can be tested without a live mach service.
///
/// Nothing here hops to the main actor. The consumer decides where the snapshot is
/// applied.
public final class AgentPushDelivery: Sendable {
  private struct Handlers {
    var onSnapshot: (@Sendable (TunnelDaemonStatusSnapshot) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?
  }

  private let handlers = Mutex(Handlers())

  public init() {}

  public func setHandlers(
    onSnapshot: @escaping @Sendable (TunnelDaemonStatusSnapshot) -> Void,
    onDisconnect: @escaping @Sendable () -> Void
  ) {
    handlers.withLock {
      $0.onSnapshot = onSnapshot
      $0.onDisconnect = onDisconnect
    }
  }

  public func clearHandlers() {
    handlers.withLock { $0 = Handlers() }
  }

  /// Decodes one pushed payload and hands the snapshot over.
  ///
  /// Anything that is not a response carrying a status is dropped rather than
  /// reported. A message the transport delivered with no payload, or one this
  /// version does not understand, says nothing about the tunnel, and passing it on
  /// as an error would replace a good reading on the screen with a false one.
  ///
  /// The closure is copied out before it is called, so a consumer that resubscribes
  /// from inside it does not deadlock on the lock this holds.
  public func deliver(payload: Data?) {
    guard let payload else {
      return
    }
    guard
      let response = try? JSONDecoder().decode(AgentControlResponse.self, from: payload),
      let status = response.status
    else {
      return
    }
    let onSnapshot = handlers.withLock { $0.onSnapshot }
    onSnapshot?(status)
  }

  /// Reports the session ending, once. Cancelling locally and hearing the peer is
  /// gone are two notices of the same disconnect, so the handlers are cleared as the
  /// first one fires and the second finds nothing to call.
  public func reportDisconnected() {
    let onDisconnect = handlers.withLock { current -> (@Sendable () -> Void)? in
      let handler = current.onDisconnect
      current = Handlers()
      return handler
    }
    onDisconnect?()
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AgentPushDeliveryTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Install the incoming-message handler on the session**

In `Sources/CellTunnelCore/AgentClient.swift`, hold the delivery on the actor. Add it after the session property at line 24:

```swift
    private var session: XPCSession?
    /// Where pushed snapshots go. Held across sessions so a reconnect keeps
    /// delivering to the same consumer.
    private nonisolated let pushDelivery = AgentPushDelivery()
```

Replace `activeSession()` at lines 363 to 386 so the session is opened with the handlers already installed. They cannot be added afterwards without racing the first push:

```swift
    private func activeSession() throws -> XPCSession {
      if let session {
        return session
      }
      let delivery = pushDelivery
      do {
        let created = try XPCSession(
          machService: agentMachServiceName,
          incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
            // A push answers nothing, so there is no reply to return. This runs on a
            // libxpc queue; the delivery is what carries it to the consumer.
            delivery.deliver(payload: Self.payloadData(from: message))
            return nil
          },
          cancellationHandler: { (_: XPCRichError) in
            delivery.reportDisconnected()
          }
        )
        session = created
        logger.notice(
          "agent xpc session opened machServiceName=\(agentMachServiceName, privacy: .public)"
        )
        return created
      } catch {
        logger.error(
          """
          agent xpc session open failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=throw-transport-failure
          """
        )
        throw TunnelDaemonError.transportFailure(
          "open agent session failed: \(error.localizedDescription)"
        )
      }
    }
```

Add the payload reader the handler and the reply path now share, next to `replyData` at line 400:

```swift
    private nonisolated static func payloadData(from message: XPCDictionary) -> Data? {
      message.withUnsafeUnderlyingDictionary { raw -> Data? in
        var length = 0
        guard
          let pointer = xpc_dictionary_get_data(raw, agentControlPayloadKey, &length),
          length > 0
        else {
          return nil
        }
        return Data(bytes: pointer, count: length)
      }
    }
```

Replace the body of `replyData(from:operationName:)` at lines 400 to 420 to use it:

```swift
    private func replyData(
      from reply: XPCDictionary,
      operationName: String
    ) throws -> Data {
      guard let data = Self.payloadData(from: reply) else {
        throw TunnelDaemonError.transportFailure(
          "agent returned no payload for \(operationName)"
        )
      }
      return data
    }
```

Report the disconnect when this side is the one ending the session, so a consumer hears it whether the agent went away or the app let go. Replace `tearDownSession(reason:)` at lines 422 to 429:

```swift
    private func tearDownSession(reason: String) {
      guard let active = session else {
        return
      }
      active.cancel(reason: reason)
      session = nil
      // A locally cancelled session may or may not run its cancellation handler, so
      // the disconnect is reported here too. The delivery reports it once either way.
      pushDelivery.reportDisconnected()
      logger.notice("agent xpc session torn down reason=\(reason, privacy: .public)")
    }
```

- [ ] **Step 6: Add the subscribe call**

In `Sources/CellTunnelCore/AgentClient.swift`, add the method to the actor body, after `status()` at line 45:

```swift
    /// Asks the agent to push a fresh snapshot whenever the state changes, and
    /// returns the snapshot as it stands now.
    ///
    /// `onSnapshot` is called for every later push and `onDisconnect` once when the
    /// session ends. Both run off the main actor, on a libxpc queue, so a caller that
    /// updates a screen has to hop for itself.
    ///
    /// The subscription lasts for the life of the session. There is no unsubscribe
    /// message: `shutdown()` ends it, and so does the agent going away.
    public func subscribe(
      onSnapshot: @escaping @Sendable (TunnelDaemonStatusSnapshot) -> Void,
      onDisconnect: @escaping @Sendable () -> Void
    ) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=subscribe")
      // The handlers go in before the request, so a snapshot the agent pushes between
      // the send and the reply is delivered rather than dropped on the floor.
      pushDelivery.setHandlers(onSnapshot: onSnapshot, onDisconnect: onDisconnect)
      do {
        let response = try await send(request: .subscribe, operationName: "subscribe")
        return try requireStatus(from: response, operationName: "subscribe")
      } catch {
        pushDelivery.clearHandlers()
        throw error
      }
    }
```

- [ ] **Step 7: Run the full gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

If the compiler cannot pick the `incomingMessageHandler` overload, the explicit `(XPCDictionary) -> XPCDictionary?` parameter and return types in Step 5 are what disambiguate it from the `Decodable` and `XPCReceivedMessage` overloads; keep them written out rather than inferred.

- [ ] **Step 8: Commit**

```bash
git add Sources/CellTunnelCore/AgentPushDelivery.swift \
  Sources/CellTunnelCore/AgentClient.swift \
  Tests/CellTunnelCoreTests/AgentPushDeliveryTests.swift
git commit -S -m "Receive agent messages that answer no request" \
  -m "The control client opened its session with no incoming-message handler, so anything the agent sent outside a reply was discarded by the transport before any code saw it." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 4: Read Mac status from the subscription instead of a poll

The Mac app asks the agent for status once a second whether or not anything changed, and each of those rounds asks a second time for a relay-service list that no Mac screen renders. An idle Mac therefore costs two cross-process round trips a second forever, and each one reads the running tunnel.

This task points the Mac at the subscription and deletes the discovery round trip. The iPhone keeps polling: it reads its own extension, not the agent, and nothing pushes to it.

What the user sees is meant to be unchanged. Two things that quietly depended on the poll are replaced rather than dropped. The install-agent setup tier appeared because a poll returned nothing; it now appears when the subscription cannot be opened or ends. The routing switch stopped spinning after a fixed number of polls; it now stops after the same number of seconds on a timer, because a request the agent never applies produces no push to count.

**Files:**
- Modify: `Apps/iOS/Services/RelayControlBackend.swift`
- Modify: `Apps/iOS/Services/AgentRelayBackend.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`
- Modify: `Apps/iOS/CellTunnelPhoneApp.swift`

**Interfaces:**
- Consumes from Task 3: `AgentClient.subscribe(onSnapshot:onDisconnect:) async throws -> TunnelDaemonStatusSnapshot` and the existing `AgentClient.shutdown()`.
- Produces: on `RelayControlBackend`, `func statusUpdates() -> AsyncStream<RelayStatusSample>?`, defaulting to `nil`, and `func sample() async -> RelayStatusSample?`, which gains a default of `nil`. A backend implements one or the other. A stream that finishes means the source is unreachable, which is what the controller reads as the agent being gone.
- No test double changes: `PhoneRelayBackend`, `SimulatorRelayBackend`, `PreviewRelayBackend`, and `UITestFixture` all keep their `sample()` and take the `statusUpdates()` default.

- [ ] **Step 1: Offer a pushed stream on the backend protocol**

In `Apps/iOS/Services/RelayControlBackend.swift`, replace the `sample()` requirement at lines 22 and 23, and extend the defaults block. A backend now provides one of the two:

```swift
  /// One status reading, or `nil` when the source is briefly unavailable. A backend
  /// whose source pushes leaves this alone and implements `statusUpdates()`.
  func sample() async -> RelayStatusSample?

  /// A stream of readings the source sends on its own, or `nil` from a source that
  /// has to be asked. The stream finishing means the source is unreachable, which is
  /// how a caller learns that without asking.
  func statusUpdates() -> AsyncStream<RelayStatusSample>?
```

Add both defaults to the existing extension:

```swift
extension RelayControlBackend {
  func sample() async -> RelayStatusSample? {
    nil
  }

  func statusUpdates() -> AsyncStream<RelayStatusSample>? {
    nil
  }

  var autoSelectsDiscoveredPeer: Bool {
    false
  }

  var usesEgressRoster: Bool {
    false
  }
}
```

Update the type's doc comment above `protocol RelayControlBackend`, which currently says the controller owns the poll cadence:

```swift
/// The platform-specific source behind the shared relay UI. The iPhone backend
/// drives the on-device relay. The Mac backend reads the agent. A backend either
/// answers one reading at a time or streams readings its source pushes, and the
/// controller owns the published state either way.
```

- [ ] **Step 2: Subscribe from the Mac backend**

In `Apps/iOS/Services/AgentRelayBackend.swift`, replace the whole `// MARK: - Sampling` section, lines 247 to 283, which is `sample()` and `discoverySnapshot()`:

```swift
    // MARK: - Status

    /// Subscribes to the agent's pushes and yields one sample per snapshot.
    ///
    /// The stream is the subscription: it opens when the controller starts iterating
    /// and finishes when the agent goes away, which is how the controller learns the
    /// agent is unreachable without asking it once a second. Ending the iteration
    /// shuts the client down, so backgrounding the app stops the pushes at the source
    /// rather than ignoring them here.
    func statusUpdates() -> AsyncStream<RelayStatusSample>? {
      let client = self.client
      return AsyncStream { continuation in
        let subscribeTask = Task {
          do {
            let current = try await client.subscribe(
              onSnapshot: { snapshot in
                continuation.yield(Self.sample(from: snapshot))
              },
              onDisconnect: {
                continuation.finish()
              }
            )
            continuation.yield(Self.sample(from: current))
            logger.notice("agent relay backend subscribed to status pushes")
          } catch {
            logger.error(
              """
              agent relay subscribe failed \
              details=\(String(describing: error), privacy: .public) recovery=end-stream
              """
            )
            continuation.finish()
          }
        }
        continuation.onTermination = { _ in
          subscribeTask.cancel()
          Task { await client.shutdown() }
        }
      }
    }

    /// Maps one agent snapshot onto the shared reading.
    ///
    /// Static and off the main actor because the pushes arrive on a libxpc queue, and
    /// nothing here touches the backend's state. The agent's snapshot reports the
    /// library rather than a saved profile, so tunnel presence is read from the
    /// library here rather than from `peerState`.
    private nonisolated static func sample(
      from snapshot: TunnelDaemonStatusSnapshot
    ) -> RelayStatusSample {
      var sample = RelayStatusSample(snapshot: snapshot)
      sample.isTunnelInstalled =
        snapshot.activeConfigID != nil || !(snapshot.configLibrary ?? []).isEmpty
      return sample
    }
```

The discovery read is gone with it. It fetched `TunnelDiscoverySnapshot` on every poll to fill `snapshot.discovery`, and no Mac screen reads it: `usesEgressRoster` is `true` on the Mac, so the peer list on screen is `connectedPeers`, the dialed-in roster the status snapshot already carries.

- [ ] **Step 3: Replace the poll loop with the update loop**

In `Apps/iOS/Services/RelayController.swift`, rename the task property at line 179 and say what it now holds:

```swift
  /// The one task reading status, whichever way the backend supplies it: iterating a
  /// pushed stream, or polling a backend that has to be asked.
  private var statusTask: Task<Void, Never>?
```

Replace `startPolling()` and `stopPolling()` at lines 416 to 447:

```swift
  private func startStatusUpdates() {
    statusTask?.cancel()
    throughput.reset()
    logger.notice("relay controller status updates starting")
    statusTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }
        await readStatusRound()
        guard !Task.isCancelled else {
          return
        }
        await Self.delay(seconds: pollIntervalSeconds)
      }
    }
  }

  // One round is either the whole life of a subscription or a single poll, depending
  // on what the backend offers. A subscription that finishes means the source went
  // away, so the loop waits and opens a new one rather than giving up: that retry is
  // what brings the Mac screen back by itself after the agent restarts.
  private func readStatusRound() async {
    if let updates = backend.statusUpdates() {
      for await sample in updates {
        apply(sample)
        #if targetEnvironment(macCatalyst)
          await refreshInstallState(agentReachable: true)
        #endif
      }
      logger.notice("relay controller status stream ended")
      #if targetEnvironment(macCatalyst)
        await refreshInstallState(agentReachable: false)
      #endif
      return
    }
    if let sample = await backend.sample() {
      apply(sample)
      #if targetEnvironment(macCatalyst)
        await refreshInstallState(agentReachable: true)
      #endif
    } else {
      #if targetEnvironment(macCatalyst)
        await refreshInstallState(agentReachable: false)
      #endif
    }
  }

  private func stopStatusUpdates() {
    logger.notice("relay controller status updates stopping")
    statusTask?.cancel()
    statusTask = nil
  }
```

Rename the two lifecycle methods at lines 402 to 412, which the scene phase calls:

```swift
  /// Stops reading status without touching the session, for backgrounding. On the Mac
  /// this ends the subscription, so the agent stops pushing to a screen nobody sees.
  func suspendStatusUpdates() {
    logger.notice("relay controller suspending status updates")
    stopStatusUpdates()
  }

  /// Resumes reading status after foregrounding.
  func resumeStatusUpdates() {
    logger.notice("relay controller resuming status updates")
    startStatusUpdates()
  }
```

Update the three remaining references to the old names: `start()` at line 321 calls `startStatusUpdates()`, and `refreshProvisioned()` at lines 344 and 354 both test `if statusTask == nil`.

- [ ] **Step 4: Time the routing request in seconds**

In `Apps/iOS/Services/RelayController.swift`, replace the two poll-count constants at lines 17 to 26. The budgets are unchanged; only the unit is, because there is no longer a poll to count:

```swift
// An unconfirmed routing-off request waits this long for the agent to apply it
// before the switch reverts to the real state, so a request that never lands cannot
// leave the spinner spinning forever. Turning off stops the relay at once, so the
// off budget is short.
private let routeIntentTimeoutSeconds: Double = 8
// Turning on starts a relay session whose connect can take up to the session connect
// timeout (~30s), so the on budget is long enough to cover the connect and the
// spinner does not snap back to off mid-connect.
private let routeConnectTimeoutSeconds: Double = 32
```

Replace the pending-request state at lines 210 to 214:

```swift
  /// The routing value the user last requested, held while a request is pending so
  /// the switch shows the requested state until the agent's real `routeState`
  /// confirms it. Only meaningful while `routeRequestPending` is true.
  private var requestedRouting = false
  /// Whether a routing request is still waiting for the agent to confirm it. A
  /// pushed update arrives only when something changes, so a request the agent never
  /// applies produces nothing to count; `routeDeadlineTask` is what ends the wait.
  private var routeRequestPending = false
  private var routeDeadlineTask: Task<Void, Never>?
```

Replace `isRouteRequestPending`, `setRouteTraffic(enabled:)`, `reconcileRouteIntent()`, and `delayBetweenPolls()` in the routing extension, lines 566 to 608:

```swift
  /// Whether a routing request is awaiting the agent's confirmation, so the derived
  /// control can report connecting.
  var isRouteRequestPending: Bool {
    routeRequestPending
  }

  func setRouteTraffic(enabled: Bool) async {
    logger.notice(
      "relay controller route traffic requested enabled=\(enabled, privacy: .public)")
    requestedRouting = enabled
    let budgetSeconds: Double
    if enabled {
      budgetSeconds = routeConnectTimeoutSeconds
    } else {
      budgetSeconds = routeIntentTimeoutSeconds
    }
    startRouteDeadline(seconds: budgetSeconds)
    await backend.setRouting(enabled: enabled)
  }

  // Gives the request a wall-clock budget. The wait is not interruptible, so a
  // confirmed request cancels the task and the late wake finds it cancelled and does
  // nothing.
  private func startRouteDeadline(seconds: Double) {
    routeDeadlineTask?.cancel()
    routeRequestPending = true
    routeDeadlineTask = Task { @MainActor [weak self] in
      await Self.delay(seconds: seconds)
      guard !Task.isCancelled else {
        return
      }
      self?.expireRouteRequest()
    }
  }

  private func expireRouteRequest() {
    guard routeRequestPending else {
      return
    }
    routeRequestPending = false
    routeDeadlineTask = nil
    logger.notice(
      "relay controller route request unconfirmed; reverting switch to real state")
  }

  // Clears the optimistic pending request once the agent's routing intent confirms
  // it, so the switch follows the confirmed value from then on.
  private func reconcileRouteIntent() {
    guard routeRequestPending, routingIntentEnabled == requestedRouting else {
      return
    }
    routeRequestPending = false
    routeDeadlineTask?.cancel()
    routeDeadlineTask = nil
  }

  /// Waits without `Task.sleep` by resuming off a dispatch queue after the given
  /// interval. Used to space polls and to time out a routing request.
  private static func delay(seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
        continuation.resume()
      }
    }
  }
```

Keep `pollIntervalSeconds` at line 15 as it is. The iPhone still polls at that cadence, and the Mac reuses it as the wait before opening a new subscription.

- [ ] **Step 5: Update the scene phase calls**

In `Apps/iOS/CellTunnelPhoneApp.swift`, replace `handleScenePhase` at lines 92 to 107:

```swift
  // The tunnel is always-on via on-demand, so backgrounding never stops it; it only
  // stops reading status to save work, and foregrounding starts reading again with a
  // fresh refresh.
  private func handleScenePhase(_ phase: ScenePhase) {
    switch phase {
    case .active:
      logger.notice("phone app scene phase active; resuming status updates")
      relayController.resumeStatusUpdates()
      Task { await relayController.refreshProvisioned() }
    case .background:
      logger.notice("phone app scene phase background; suspending status updates")
      relayController.suspendStatusUpdates()
    default:
      break
    }
  }
```

- [ ] **Step 6: Run the full gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

`RelayController` and the backends live in the Tuist app target, which has no unit test bundle, and the behavior needs a running agent on the other end of a mach service. There is no unit test for this task. Step 7 is the check.

- [ ] **Step 7: Verify against the running agent**

Install and launch the built app and agent, then watch the control traffic:

```bash
log stream --style compact --predicate \
  'subsystem == "io.goodkind.celltunnel" AND category == "daemon"'
```

Expected, with the app in the foreground and routing off:
- One `agent client invoked rpc=subscribe` and one `agent session listener registered subscriber` when the app starts.
- No repeating `rpc=status` line. Before this task there was one per second.
- `agent status pushed` only when something changes.

Then toggle Route traffic on and confirm the screen follows without a poll: `agent status pushed` appears on the change, `agent status push timer started` appears, and the byte counters advance on screen while traffic flows. Toggle it off and confirm the pushes stop advancing.

Then quit the app and confirm `agent session listener removed subscriber`, and that no pushes follow.

Last, kill the agent while the app is running: the screen must fall back to the install-agent setup tier, and it must recover on its own when the agent comes back, which is `relay controller status stream ended` followed by a new subscribe a second later.

- [ ] **Step 8: Commit**

```bash
git add Apps/iOS/Services/RelayControlBackend.swift \
  Apps/iOS/Services/AgentRelayBackend.swift \
  Apps/iOS/Services/RelayController.swift \
  Apps/iOS/CellTunnelPhoneApp.swift
git commit -S -m "Read Mac status from the agent subscription" \
  -m "The Mac app asked the agent for status once a second whether or not anything had changed, and each round asked a second time for a relay-service list no Mac screen rendered." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

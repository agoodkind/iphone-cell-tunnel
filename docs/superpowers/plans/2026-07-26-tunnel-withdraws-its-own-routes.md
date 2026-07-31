# Tunnel Withdraws Its Own Routes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop traffic from being dropped when the Mac agent goes away, by having the packet tunnel notice the loss and withdraw its own routes so traffic falls back to the physical interface.

**Architecture:** The Mac packet tunnel extension is a separate process that outlives the agent. It reaches the agent over loopback UDP and holds the routes and resolver through `RouteGate`. Today nothing tells it the agent has gone, so it keeps routes pointed at a relay bridge that no longer exists and traffic is dropped silently. This plan gives the extension a liveness check on its loopback path and has it withdraw routes when that check fails, which covers a crash, a logout, a forced quit, and an upgrade with one mechanism and no cooperation from the dying process.

**Tech Stack:** Swift 6, Swift Testing (`@Test` / `#expect`), SwiftPM for `Sources/CellTunnelCore` and `Tests/CellTunnelCoreTests`, Tuist for the app targets, NetworkExtension.

## Global Constraints

- Cleanup must not depend on the agent doing anything as it exits. A crashed or force-quit process runs no code, so any design that relies on a farewell message is wrong.
- The decision of when to treat the agent as gone is a pure function in `Sources/CellTunnelCore`, with tests. The extension supplies observations and applies the result.
- Tests live in `Tests/CellTunnelCoreTests` and use Swift Testing, not XCTest.
- A new file in `Sources/` must be reachable from a SwiftPM target or the `lint-deadcode` gate fails it.
- Enum cases must be declared in alphabetical order; `lint-swiftlint` enforces it.
- An access modifier goes on each member, not on the `extension`.
- Vertical whitespace is limited to a single empty line.
- Build and gate with the repo's dev tool, not `swift build`:
  `SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic swift Tools/cell-tunnel-dev.swift build mac Debug`
- Run package tests with `swift test --filter <SuiteName>` from the repo root.

---

### Task 1: Decide when the agent counts as gone

The extension needs a rule for turning "I have not heard from the agent" into "withdraw the routes". A rule that fires too eagerly drops a working tunnel during a brief stall; one that never fires leaves traffic in a black hole. This task builds the rule and its tests. Task 2 wires the extension to it.

**Files:**
- Create: `Sources/CellTunnelCore/RelayLiveness.swift`
- Test: `Tests/CellTunnelCoreTests/RelayLivenessTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `RelayLiveness`, a `public struct` with `public init(missedRepliesBeforeGone: Int)`, `public mutating func recordReply() -> RelayLivenessVerdict`, and `public mutating func recordMissedReply() -> RelayLivenessVerdict`. Also `RelayLivenessVerdict`, a `public enum` with cases `gone`, `live`, and `unchanged`. Task 2 calls both record methods and switches over the verdict.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/RelayLivenessTests.swift`:

```swift
//
//  RelayLivenessTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

@Suite("Relay liveness")
struct RelayLivenessTests {
  /// A single missed reply is a stall, not a death. Withdrawing routes on one
  /// miss would drop a working tunnel every time the agent is briefly busy.
  @Test("one missed reply does not declare the agent gone")
  func oneMissIsNotGone() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 3)
    #expect(liveness.recordMissedReply() == .unchanged)
  }

  @Test("the configured number of consecutive misses declares the agent gone")
  func enoughMissesDeclareGone() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 3)
    #expect(liveness.recordMissedReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .gone)
  }

  /// The verdict reports the transition, not the state, so the caller withdraws
  /// routes once rather than on every tick after the agent dies.
  @Test("staying gone reports no further change")
  func goneIsReportedOnce() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 2)
    _ = liveness.recordMissedReply()
    #expect(liveness.recordMissedReply() == .gone)
    #expect(liveness.recordMissedReply() == .unchanged)
  }

  /// A reply inside the window clears the count, so an agent that stalls and
  /// recovers keeps its routes.
  @Test("a reply clears the miss count")
  func replyClearsTheCount() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 3)
    _ = liveness.recordMissedReply()
    _ = liveness.recordMissedReply()
    #expect(liveness.recordReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .gone)
  }

  /// An agent that comes back reports the transition, so the caller can restore
  /// routes once rather than on every reply.
  @Test("a reply after being gone reports the agent live again")
  func replyAfterGoneReportsLive() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 1)
    #expect(liveness.recordMissedReply() == .gone)
    #expect(liveness.recordReply() == .live)
    #expect(liveness.recordReply() == .unchanged)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter RelayLivenessTests`
Expected: FAIL to compile, `cannot find 'RelayLiveness' in scope`.

- [ ] **Step 3: Write the rule**

Create `Sources/CellTunnelCore/RelayLiveness.swift`:

```swift
//
//  RelayLiveness.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

// MARK: - RelayLivenessVerdict

/// What changed about the agent's liveness, rather than what it currently is.
///
/// The caller withdraws or restores routes on a transition, so reporting the
/// state on every observation would make it withdraw repeatedly while nothing
/// had changed.
public enum RelayLivenessVerdict: Equatable, Sendable {
  /// The agent has stopped answering and its routes should be withdrawn.
  case gone
  /// The agent is answering again and its routes can be restored.
  case live
  /// Nothing changed, so the caller does nothing.
  case unchanged
}

// MARK: - RelayLiveness

/// Turns a run of unanswered messages into a decision about whether the agent
/// has gone away.
///
/// The packet tunnel outlives the agent and holds the routes, so it is the only
/// process that can clean up after an agent that crashed, was force quit, or
/// went away with the login session. A dying process runs no code, so the
/// decision cannot wait for the agent to announce anything.
///
/// A single unanswered message means the agent was busy, so acting on one would
/// drop a working tunnel. Requiring several consecutive misses distinguishes a
/// stall from a death.
public struct RelayLiveness: Sendable {
  private let missedRepliesBeforeGone: Int
  private var consecutiveMisses = 0
  private var isGone = false

  public init(missedRepliesBeforeGone: Int) {
    self.missedRepliesBeforeGone = max(1, missedRepliesBeforeGone)
  }

  /// Records that the agent answered.
  public mutating func recordReply() -> RelayLivenessVerdict {
    consecutiveMisses = 0
    guard isGone else {
      return .unchanged
    }
    isGone = false
    return .live
  }

  /// Records that the agent did not answer.
  public mutating func recordMissedReply() -> RelayLivenessVerdict {
    guard !isGone else {
      return .unchanged
    }
    consecutiveMisses += 1
    guard consecutiveMisses >= missedRepliesBeforeGone else {
      return .unchanged
    }
    isGone = true
    return .gone
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter RelayLivenessTests`
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
git add Sources/CellTunnelCore/RelayLiveness.swift Tests/CellTunnelCoreTests/RelayLivenessTests.swift
git commit -S -m "Decide when the relay agent counts as gone" \
  -m "The packet tunnel outlives the agent and holds the routes, so it is the only process able to clean up after one that crashed or was force quit. Several consecutive unanswered messages separate a stall from a death." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 2: Withdraw the tunnel's routes when the agent stops answering

Kill the Mac agent while the tunnel is up and every captured packet disappears. The extension keeps the routes installed and keeps handing datagrams to a loopback socket whose listener died with the agent, so the Mac has no working path until someone notices and stops the VPN by hand. Two things have to change for the extension to see it. Nothing on the socket reports the loss today, because the outbound counters rise on a fire-and-forget send whether or not anyone is listening, so the extension needs its own keepalive and an answer from the agent. The relay receive loop also stops re-arming after its first receive error, so it would go deaf before the keepalive ever reported anything.

The keepalive reuses `RelayHeartbeat`, the one-byte datagram the iPhone links already use, so no new wire type appears. The agent answers it on the loopback connection instead of forwarding it to the iPhone, matching what its phone-link path already does. WireGuard's smallest message is far larger than one byte, so a keepalive is never mistaken for traffic in either direction.

**Files:**
- Create: `Apps/macOS/TunnelProvider/Runtime/RelayLivenessMonitor.swift`
- Modify: `Apps/macOS/TunnelProvider/Runtime/RelayTransport.swift`
- Modify: `Apps/macOS/TunnelProvider/PacketTunnelProvider.swift`
- Modify: `Apps/macOS/Agent/AgentRelayBridge+Receive.swift`
- Modify: `Package.swift`
- Test: `Tests/CellTunnelCoreTests/EchoingAgentListener.swift`
- Test: `Tests/CellTunnelCoreTests/RelayTransportReceiveTests.swift`
- Test: `Tests/CellTunnelCoreTests/RelayLivenessMonitorTests.swift`

**Interfaces:**
- Consumes: `RelayLiveness` from Task 1, through `public init(missedRepliesBeforeGone: Int)`, `public mutating func recordReply() -> RelayLivenessVerdict`, and `public mutating func recordMissedReply() -> RelayLivenessVerdict`, switching over `RelayLivenessVerdict.gone`, `.live`, and `.unchanged`. Also `RelayHeartbeat.payload` and `RelayHeartbeat.isHeartbeat(_:)` from `CellTunnelCore`, and `RouteGate.setInstalled(_:) -> NEPacketTunnelNetworkSettings?`.
- Produces: `RelayLivenessMonitor`, a `final class` with `init(transport: RelayTransport, missedRepliesBeforeGone: Int, intervalMilliseconds: Int)`, `var onAgentGone: (@Sendable () -> Void)?`, `func start()`, and `func stop()`. `RelayTransport` gains `func reconnect()` and `var onKeepaliveReply: (() -> Void)?`. A SwiftPM target `CellTunnelTunnelRuntime` makes the extension's runtime files reachable from the package tests.

Three design choices are worth stating before the steps, because each one could reasonably have gone another way.

The timer lives in `RelayLivenessMonitor` on its own queue, alongside the `RelayLiveness` value it feeds, so no new thread touches a stored property of `PacketTunnelProvider`. The verdict reaches `applyRouteState` by a closure called on the monitor's queue, which is safe because that method reads no stored property of the provider except the lock-guarded `routeGate` before handing the settings to `super.setTunnelNetworkSettings`. The serialization NetworkExtension gives the lifecycle callbacks is left intact.

Coming back from `gone` does not install routes. The agent owns the install decision and re-asserts it over the control channel when a phone link comes up, so installing on the agent's return would capture traffic with no link to carry it, which is the black hole this plan exists to close.

The monitor redials the transport on every tick while it believes the agent is gone. Without that, an agent that restarts finds the extension pointed at a connection that failed on the ICMP unreachable its own keepalives provoked, and the agent's control channel is a separate path that would happily ask for routes to be installed over the dead socket.

- [ ] **Step 1: Make the extension's runtime reachable from the package tests**

Nothing under `Apps/macOS/TunnelProvider/` is testable today, so map the runtime files that carry this behavior into a SwiftPM target, the way `CellTunnelCatalystPresentation` already maps a file out of `Apps/iOS/Presentation`. `PacketTunnelProvider.swift` stays out because it imports WireGuardKit.

In `Package.swift`, add the target after `CellTunnelSignalSupport`:

```swift
    // The tunnel extension's runtime is otherwise reachable only through the
    // Tuist app target, which no test target depends on. These three files hold
    // the route gate, the relay socket, and the liveness rule that withdraws
    // routes, so they are mapped here to be driven from the package tests.
    .target(
      name: "CellTunnelTunnelRuntime",
      dependencies: [
        "CellTunnelCore",
        "CellTunnelLog",
      ],
      path: "Apps/macOS/TunnelProvider/Runtime",
      sources: [
        "RelayTransport.swift",
        "RouteGate.swift",
      ]
    ),
```

Add the dependency to the test target:

```swift
    .testTarget(
      name: "CellTunnelCoreTests",
      dependencies: [
        "CellTunnelCatalystPresentation",
        "CellTunnelCore",
        "CellTunnelLog",
        "CellTunnelTunnelRuntime",
      ]
    ),
```

- [ ] **Step 2: Write the failing receive loop test**

Create `Tests/CellTunnelCoreTests/EchoingAgentListener.swift`:

```swift
//
//  EchoingAgentListener.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Network

/// A stand-in for the agent's relay bridge, bound to an ephemeral loopback port.
///
/// The tests need a real socket on the other end of `RelayTransport`, because the
/// behavior under test is what the extension does when its peer stops answering,
/// and that is a property of the socket rather than of any object it holds.
/// Cancelling this listener is how a test makes the agent go away.
final class EchoingAgentListener: @unchecked Sendable {
  /// What the stand-in sends back for each datagram it receives.
  enum ReplyMode {
    /// An empty datagram followed by real traffic, which is what makes the
    /// extension's receive call fail once and then have something left to deliver.
    case emptyThenPayload
    /// The heartbeat echo the real agent answers the extension's keepalive with.
    case heartbeat
  }

  /// The traffic payload sent after the empty datagram, sized well past the
  /// one-byte heartbeat so the transport treats it as relay traffic.
  static let trafficPayload = Data(repeating: 0xAB, count: 64)

  private let mode: ReplyMode
  private let queue = DispatchQueue(label: "io.goodkind.celltunnel.test.echoAgent")
  private var listener: NWListener?
  private var connections: [NWConnection] = []

  init(mode: ReplyMode) {
    self.mode = mode
  }

  /// Binds an ephemeral UDP port and returns it once the listener is ready, so a
  /// test dials a port that is certainly open.
  func start() async throws -> NWEndpoint.Port {
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    let nwListener = try NWListener(using: parameters, on: .any)
    listener = nwListener
    nwListener.newConnectionHandler = { [weak self] connection in
      self?.adopt(connection)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let box = ListenerReadyBox(continuation)
      nwListener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          box.resume(returning: nwListener.port ?? .any)
        case .failed(let error):
          box.resume(throwing: error)
        default:
          break
        }
      }
      nwListener.start(queue: queue)
    }
  }

  /// Stops answering, which is what the extension sees when the agent dies.
  func stop() {
    queue.sync {
      for connection in connections {
        connection.cancel()
      }
      connections = []
      listener?.cancel()
      listener = nil
    }
  }

  private func adopt(_ connection: NWConnection) {
    connections.append(connection)
    connection.start(queue: queue)
    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self else {
        return
      }
      if data != nil, error == nil {
        reply(on: connection)
      }
      guard error == nil else {
        return
      }
      receive(on: connection)
    }
  }

  private func reply(on connection: NWConnection) {
    switch mode {
    case .emptyThenPayload:
      // Chaining the traffic off the empty datagram's completion keeps the two in
      // order, so the test always sees the error before the payload it must still
      // deliver.
      connection.send(
        content: Data(),
        completion: .contentProcessed { _ in
          connection.send(content: Self.trafficPayload, completion: .idempotent)
        }
      )
    case .heartbeat:
      connection.send(content: RelayHeartbeat.payload, completion: .idempotent)
    }
  }
}

/// Guards the listener's readiness continuation, because a Network listener can
/// report a state more than once and resuming a continuation twice traps.
private final class ListenerReadyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<NWEndpoint.Port, Error>?

  init(_ continuation: CheckedContinuation<NWEndpoint.Port, Error>) {
    self.continuation = continuation
  }

  func resume(returning port: NWEndpoint.Port) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(returning: port)
  }

  func resume(throwing error: Error) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(throwing: error)
  }
}

/// Collects what the transport delivered, since the delivery closure runs on the
/// transport's receive queue and the test reads it from the main actor.
final class ReceivedDatagrams: @unchecked Sendable {
  private let lock = NSLock()
  private var datagrams: [Data] = []

  func append(_ datagram: Data) {
    lock.lock()
    defer { lock.unlock() }
    datagrams.append(datagram)
  }

  func contains(_ datagram: Data) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return datagrams.contains(datagram)
  }
}
```

Create `Tests/CellTunnelCoreTests/RelayTransportReceiveTests.swift`:

```swift
//
//  RelayTransportReceiveTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Network
import Testing

@testable import CellTunnelTunnelRuntime

@MainActor
@Suite("Relay transport receive")
struct RelayTransportReceiveTests {
  /// A receive error is not the end of the socket. The agent sends empty
  /// datagrams, which surface as ENODATA, and a dead listener surfaces as
  /// ECONNREFUSED. A loop that gives up on the first of those leaves the
  /// extension deaf for the rest of the tunnel's life, which would also make the
  /// liveness keepalive report the agent gone forever.
  @Test("traffic still arrives after a receive error")
  func trafficArrivesAfterAReceiveError() async throws {
    let agent = EchoingAgentListener(mode: .emptyThenPayload)
    let port = try await agent.start()
    let transport = RelayTransport(metrics: RelayMetrics())
    let received = ReceivedDatagrams()
    transport.onReceive = { datagram in
      received.append(datagram)
    }
    try transport.connect(to: .hostPort(host: "127.0.0.1", port: port))
    transport.send(Data(repeating: 0x01, count: 32))

    let delivered = await waitUntil(timeoutSeconds: 5) {
      received.contains(EchoingAgentListener.trafficPayload)
    }
    transport.disconnect()
    agent.stop()

    #expect(delivered)
  }

  /// Polls until the condition holds, so a real socket decides the timing rather
  /// than a fixed sleep long enough to be slow and short enough to be flaky.
  private func waitUntil(timeoutSeconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if condition() {
        return true
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }
}
```

- [ ] **Step 3: Run the receive loop test to verify it fails**

Run: `swift test --filter RelayTransportReceiveTests`
Expected: FAIL, `Expectation failed: delivered`. The empty datagram ends the receive loop, so the traffic behind it never reaches `onReceive`.

- [ ] **Step 4: Keep the relay receive loop alive and take the keepalive reply out of the traffic path**

Replace `Apps/macOS/TunnelProvider/Runtime/RelayTransport.swift` with:

```swift
//
//  RelayTransport.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

enum RelayTransportError: LocalizedError {
  case alreadyConnected
  case invalidEndpoint
  case notConnected

  var errorDescription: String? {
    switch self {
    case .alreadyConnected:
      return "relay transport already connected"
    case .invalidEndpoint:
      return "relay transport endpoint invalid"
    case .notConnected:
      return "relay transport not connected"
    }
  }
}

// MARK: - RelayTransport

final class RelayTransport: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.goodkind.celltunnel.relay")
  private let metrics: RelayMetrics
  // The liveness monitor replaces the connection from its own queue while
  // WireGuard sends on another, so both sides take this lock. An uncontended lock
  // costs far less than the datagram send it guards.
  private let stateLock = NSLock()
  private var connection: NWConnection?
  private var endpoint: NWEndpoint?
  var onReceive: ((Data) -> Void)?
  /// Called when the agent echoes the liveness keepalive.
  var onKeepaliveReply: (() -> Void)?

  init(metrics: RelayMetrics) {
    self.metrics = metrics
  }

  func connect(to endpoint: NWEndpoint) throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard connection == nil else {
      throw RelayTransportError.alreadyConnected
    }
    self.endpoint = endpoint
    startLocked(to: endpoint)
  }

  /// Drops the socket and dials the same endpoint again.
  ///
  /// The agent hosts the listener on the other end, so an agent that died takes
  /// the flow with it and leaves this connection failed on the ICMP unreachable
  /// its own sends provoke. A failed connection never recovers on its own, so the
  /// liveness monitor redials while it believes the agent is gone and a restarted
  /// agent is found again instead of being talked at through a dead socket.
  func reconnect() {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let endpoint else {
      return
    }
    connection?.cancel()
    connection = nil
    startLocked(to: endpoint)
  }

  func send(_ datagram: Data) {
    stateLock.lock()
    let activeConnection = connection
    stateLock.unlock()
    guard let activeConnection else {
      metrics.addDropped()
      logger.error(
        """
        relay transport send failed error=not-connected \
        bytes=\(datagram.count, privacy: .public)
        """
      )
      return
    }
    let relayMetrics = self.metrics
    activeConnection.send(
      content: datagram,
      completion: .contentProcessed { error in
        guard let error else {
          return
        }
        relayMetrics.addDropped()
        logger.error(
          """
          relay transport send failed \
          error=\(error.localizedDescription, privacy: .public)
          """
        )
      }
    )
  }

  func disconnect() {
    stateLock.lock()
    let activeConnection = connection
    connection = nil
    // Forgetting the endpoint is what stops a redial from resurrecting the socket
    // after the tunnel has stopped.
    endpoint = nil
    stateLock.unlock()
    guard let activeConnection else {
      return
    }
    activeConnection.cancel()
    logger.notice("relay transport disconnected")
  }

  private func startLocked(to endpoint: NWEndpoint) {
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true
    let nwConnection = NWConnection(to: endpoint, using: parameters)
    nwConnection.stateUpdateHandler = { state in
      switch state {
      case .waiting(let error):
        logger.error(
          """
          relay transport waiting error=\(error.localizedDescription, privacy: .public) \
          endpoint=\(String(describing: endpoint), privacy: .public)
          """
        )
      case .failed(let error):
        logger.error(
          """
          relay transport failed error=\(error.localizedDescription, privacy: .public) \
          endpoint=\(String(describing: endpoint), privacy: .public)
          """
        )
      default:
        logger.notice(
          """
          relay transport state=\(String(describing: state), privacy: .public) \
          endpoint=\(String(describing: endpoint), privacy: .public)
          """
        )
      }
    }
    nwConnection.start(queue: queue)
    connection = nwConnection
    receiveLoop(on: nwConnection)
    logger.notice(
      "relay transport connecting endpoint=\(String(describing: endpoint), privacy: .public)"
    )
  }

  private func receiveLoop(on activeConnection: NWConnection) {
    activeConnection.receiveMessage { [weak self] data, _, _, error in
      guard let self else {
        return
      }
      if let data, !data.isEmpty {
        deliver(data)
      }
      if let error {
        logger.error(
          "relay transport receive failed error=\(error.localizedDescription, privacy: .public)"
        )
        // One receive error does not end the socket. An empty datagram surfaces as
        // ENODATA and a listener that went away surfaces as ECONNREFUSED, and real
        // traffic can follow either one, so giving up here left the extension deaf
        // for the rest of the tunnel's life. Only a terminal state stops the loop,
        // which is what keeps it from spinning on a cancelled socket.
        switch activeConnection.state {
        case .cancelled, .failed:
          logger.notice("relay transport receive loop ended state=terminal")
          return
        default:
          break
        }
      }
      receiveLoop(on: activeConnection)
    }
  }

  // The agent answers the liveness keepalive on this same socket, so the echo is
  // taken here rather than injected into WireGuard, which would be handed a
  // one-byte datagram it cannot parse and would count it as relay traffic.
  private func deliver(_ datagram: Data) {
    if RelayHeartbeat.isHeartbeat(datagram) {
      onKeepaliveReply?()
      return
    }
    guard let onReceive else {
      metrics.addDropped()
      return
    }
    onReceive(datagram)
  }
}
```

- [ ] **Step 5: Run the receive loop test to verify it passes**

Run: `swift test --filter RelayTransportReceiveTests`
Expected: PASS, 1 test.

- [ ] **Step 6: Write the failing liveness monitor test**

Create `Tests/CellTunnelCoreTests/RelayLivenessMonitorTests.swift`:

```swift
//
//  RelayLivenessMonitorTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Network
import NetworkExtension
import Testing

@testable import CellTunnelTunnelRuntime

@MainActor
@Suite("Relay liveness monitor")
struct RelayLivenessMonitorTests {
  /// The whole point of the change, driven end to end over a real loopback
  /// socket: while the agent answers, a working tunnel keeps its routes, and when
  /// the agent's listener goes away the gate withdraws the captured routes and the
  /// tunnel resolver so traffic falls back to the physical interface.
  @Test("routes stay installed while the agent answers and withdraw when it stops")
  func agentGoingAwayWithdrawsRoutes() async throws {
    let agent = EchoingAgentListener(mode: .heartbeat)
    let port = try await agent.start()
    let gate = RouteGate()
    let settings = Self.makeSettings()
    _ = gate.record(settings)
    _ = gate.setProgramRoutes(
      ipv4: [NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0")],
      ipv6: []
    )
    _ = gate.setProgramDNS(servers: ["10.0.0.1"], searchDomains: [])
    _ = gate.setInstalled(true)
    #expect(settings.ipv4Settings?.includedRoutes?.isEmpty == false)
    #expect(settings.dnsSettings != nil)

    let transport = RelayTransport(metrics: RelayMetrics())
    try transport.connect(to: .hostPort(host: "127.0.0.1", port: port))
    let monitor = RelayLivenessMonitor(
      transport: transport,
      missedRepliesBeforeGone: 2,
      intervalMilliseconds: 100
    )
    monitor.onAgentGone = { [gate] in
      _ = gate.setInstalled(false)
    }
    monitor.start()

    // Several ticks with the agent answering must leave a working tunnel alone.
    try await Task.sleep(for: .milliseconds(500))
    #expect(gate.isInstalled)

    agent.stop()
    let withdrew = await waitUntil(timeoutSeconds: 5) {
      !gate.isInstalled
    }
    monitor.stop()
    transport.disconnect()

    #expect(withdrew)
    #expect(settings.ipv4Settings?.includedRoutes?.isEmpty == true)
    #expect(settings.dnsSettings == nil)
  }

  private static func makeSettings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.ipv4Settings = NEIPv4Settings(
      addresses: ["10.0.0.2"],
      subnetMasks: ["255.255.255.0"]
    )
    return settings
  }

  /// Polls until the condition holds, so a real timer and a real socket decide the
  /// timing rather than a fixed sleep.
  private func waitUntil(timeoutSeconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if condition() {
        return true
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }
}
```

- [ ] **Step 7: Run the monitor test to verify it fails**

Run: `swift test --filter RelayLivenessMonitorTests`
Expected: FAIL to compile, `cannot find 'RelayLivenessMonitor' in scope`.

- [ ] **Step 8: Add the liveness monitor**

Create `Apps/macOS/TunnelProvider/Runtime/RelayLivenessMonitor.swift`:

```swift
//
//  RelayLivenessMonitor.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Synchronization

private let logger = CellTunnelLog.logger(category: .relay)

/// Watches the loopback socket the extension shares with the agent and reports
/// when the agent stops answering.
///
/// The extension outlives the agent and holds the routes, so an agent that
/// crashed, was force quit, or went away with the login session leaves every
/// captured packet pointed at a relay bridge that no longer exists. The existing
/// counters cannot tell that apart from an idle tunnel, because the outbound
/// counters rise on a fire-and-forget send whether or not anyone is listening, so
/// this sends its own keepalive and waits for the agent's echo.
///
/// The timer runs on its own queue and the liveness state is touched only there,
/// which leaves the provider's stored state under the serialization
/// NetworkExtension gives the tunnel lifecycle callbacks.
final class RelayLivenessMonitor: @unchecked Sendable {
  private let transport: RelayTransport
  private let intervalMilliseconds: Int
  private let queue = DispatchQueue(label: "io.goodkind.celltunnel.relayLiveness")
  // Set from the transport's receive queue and cleared on the timer queue, so it
  // crosses queues and is atomic rather than lock guarded.
  private let sawReply = Atomic<Bool>(false)
  private var liveness: RelayLiveness
  private var timer: DispatchSourceTimer?
  private var isGone = false

  /// Fired once when the agent stops answering, so the caller withdraws routes.
  var onAgentGone: (@Sendable () -> Void)?

  init(transport: RelayTransport, missedRepliesBeforeGone: Int, intervalMilliseconds: Int) {
    self.transport = transport
    self.intervalMilliseconds = intervalMilliseconds
    self.liveness = RelayLiveness(missedRepliesBeforeGone: missedRepliesBeforeGone)
  }

  func start() {
    transport.onKeepaliveReply = { [weak self] in
      self?.sawReply.store(true, ordering: .relaxed)
    }
    // Ask before the first tick judges, so that tick weighs an answer to a
    // keepalive that was actually sent.
    transport.send(RelayHeartbeat.payload)
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(
      deadline: .now() + .milliseconds(intervalMilliseconds),
      repeating: .milliseconds(intervalMilliseconds)
    )
    source.setEventHandler { [weak self] in
      self?.tick()
    }
    timer = source
    source.resume()
    logger.notice(
      "relay liveness monitor started interval_ms=\(intervalMilliseconds, privacy: .public)"
    )
  }

  func stop() {
    timer?.cancel()
    timer = nil
    transport.onKeepaliveReply = nil
    logger.notice("relay liveness monitor stopped")
  }

  private func tick() {
    let replied = sawReply.exchange(false, ordering: .relaxed)
    let verdict: RelayLivenessVerdict
    if replied {
      verdict = liveness.recordReply()
    } else {
      verdict = liveness.recordMissedReply()
    }
    switch verdict {
    case .gone:
      isGone = true
      logger.error("relay liveness lost agent recovery=withdraw-routes")
      onAgentGone?()
    case .live:
      isGone = false
      // Routes are not installed here. The agent owns that decision and re-asserts
      // it over the control channel once a phone link is up, so installing on the
      // agent's return would capture traffic with no link to carry it.
      logger.notice("relay liveness regained agent recovery=await-agent-route-state")
    case .unchanged:
      break
    }
    if isGone {
      transport.reconnect()
    }
    transport.send(RelayHeartbeat.payload)
  }
}
```

Add the new file to the SwiftPM target's sources in `Package.swift`, keeping them alphabetical:

```swift
      sources: [
        "RelayLivenessMonitor.swift",
        "RelayTransport.swift",
        "RouteGate.swift",
      ]
```

- [ ] **Step 9: Run the monitor test to verify it passes**

Run: `swift test --filter RelayLivenessMonitorTests`
Expected: PASS, 1 test.

- [ ] **Step 10: Answer the extension's keepalive in the agent relay bridge**

The extension's keepalive arrives on the agent's loopback connection, where every non-empty datagram is currently forwarded to the carrying phone link. Forwarding it would send the keepalive to the iPhone, which echoes it back into the phone link, so it would never reach the extension and the extension would call a healthy agent dead. Answer it on the loopback connection instead, the way the phone link path already does.

In `Apps/macOS/Agent/AgentRelayBridge+Receive.swift`, replace `handleMacReceive` with:

```swift
  // The Mac loopback receive: answer the extension's liveness keepalive, forward
  // real data to the carrying phone link, and tear the bridge down on a receive
  // error, since the extension connection is the single downstream side.
  private func handleMacReceive(_ connection: NWConnection, data: Data?, error: NWError?) {
    if let error {
      logger.error(
        """
        agent relay bridge receive failed mac=true \
        error=\(error.localizedDescription, privacy: .public)
        """
      )
      connection.cancel()
      clearIfCurrent(connection, isLoopback: true, reason: "receive-error")
      return
    }
    if let data, !data.isEmpty {
      // The extension keepalives this socket to decide whether this process is
      // still alive, so the heartbeat is answered here. Forwarding it would send
      // it to the iPhone, which echoes it back into the phone link, and the
      // extension would never hear an answer.
      if RelayHeartbeat.isHeartbeat(data) {
        sendHeartbeatEcho(on: connection)
      } else {
        forward(data, fromMac: true)
      }
    }
    receive(on: connection, fromMac: true)
  }
```

- [ ] **Step 11: Start the monitor from the packet tunnel provider**

In `Apps/macOS/TunnelProvider/PacketTunnelProvider.swift`, add the constants next to `agentLoopbackHost`:

```swift
// The extension keepalives the agent over loopback and treats a run of
// unanswered keepalives as the agent being gone. Loopback does not lose
// datagrams, so a miss means the agent is not servicing its socket; three of them
// at two seconds tolerates a briefly stalled agent while keeping the window in
// which traffic is black holed to a few seconds.
private let relayKeepaliveIntervalMilliseconds = 2_000
private let relayMissedKeepalivesBeforeGone = 3
```

Add the stored property after `throughputLogger`:

```swift
  private var livenessMonitor: RelayLivenessMonitor?
```

Add the start after `relayThroughputLogger.start()` in `runStartTunnel`:

```swift
    let livenessMonitor = RelayLivenessMonitor(
      transport: relayTransport,
      missedRepliesBeforeGone: relayMissedKeepalivesBeforeGone,
      intervalMilliseconds: relayKeepaliveIntervalMilliseconds
    )
    // The callback runs on the monitor's queue. applyRouteState reads no stored
    // property of this class other than the lock-guarded route gate before it
    // hands the settings to NetworkExtension, so calling it from there leaves the
    // serialization of the lifecycle callbacks intact.
    livenessMonitor.onAgentGone = { [weak self] in
      self?.applyRouteState(false)
    }
    self.livenessMonitor = livenessMonitor
    livenessMonitor.start()
```

Add the stop at the top of `stopTunnel`, before `throughputLogger?.stop()`:

```swift
    // Stop the monitor before the transport, so a tick already in flight cannot
    // redial the socket this shutdown is closing.
    livenessMonitor?.stop()
    livenessMonitor = nil
```

- [ ] **Step 12: Run the full gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

- [ ] **Step 13: Verify against an agent that is killed**

The agent's half of the keepalive has no unit test, because standing the real relay bridge up in a test process would bind the fixed relay port and advertise its Bonjour service. Check it against the running system instead.

Start the tunnel with an iPhone link up, confirm traffic flows, then watch the log:

```bash
log stream --style compact --predicate 'eventMessage CONTAINS "relay liveness" OR eventMessage CONTAINS "route state applied"'
```

In a second terminal, kill the agent without letting it run any cleanup:

```bash
pkill -9 -f CellTunnelAgent
```

Expected in the log stream within about eight seconds:
```
relay liveness lost agent recovery=withdraw-routes
route state applied installed=false
```

Confirm the captured routes are gone and traffic is back on the physical interface:

```bash
netstat -rn -f inet
```
Expected: no route through the tunnel's `utun` interface, and the default route back on the physical uplink.

Restart the agent, reconnect the iPhone, and confirm the tunnel recovers:
```
relay liveness regained agent recovery=await-agent-route-state
route state applied installed=true
```

- [ ] **Step 14: Commit**

```bash
git add Package.swift \
  Apps/macOS/Agent/AgentRelayBridge+Receive.swift \
  Apps/macOS/TunnelProvider/PacketTunnelProvider.swift \
  Apps/macOS/TunnelProvider/Runtime/RelayLivenessMonitor.swift \
  Apps/macOS/TunnelProvider/Runtime/RelayTransport.swift \
  Tests/CellTunnelCoreTests/EchoingAgentListener.swift \
  Tests/CellTunnelCoreTests/RelayLivenessMonitorTests.swift \
  Tests/CellTunnelCoreTests/RelayTransportReceiveTests.swift
git commit -S -m "Withdraw the tunnel's routes when the relay agent stops answering" \
  -m "Nothing told the extension its agent had gone, so a crash or a force quit left the routes and the tunnel resolver installed and every captured packet aimed at a loopback socket whose listener had died with the agent. The relay receive loop also stopped re-arming after its first receive error, which left the extension deaf for the rest of the tunnel's life even once the agent came back." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

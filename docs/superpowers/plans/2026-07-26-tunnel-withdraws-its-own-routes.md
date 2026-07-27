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

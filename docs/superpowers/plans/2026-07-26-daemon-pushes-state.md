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

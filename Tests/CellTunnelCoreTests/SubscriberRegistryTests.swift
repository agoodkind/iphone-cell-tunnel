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
      received.withLock { $0.append("first:" + (String(bytes: data, encoding: .utf8) ?? "")) }
    }
    _ = registry.add { data in
      received.withLock { $0.append("second:" + (String(bytes: data, encoding: .utf8) ?? "")) }
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
    #expect(registry.isEmpty)
    let first = registry.add { _ in
      // The count is what this test observes, not the payload.
    }
    _ = registry.add { _ in
      // Same here: presence is what matters.
    }
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
    #expect(registry.isEmpty)
  }

  @Test("a broadcast with no subscribers does nothing")
  func broadcastWithNoSubscribersDoesNothing() {
    let registry = SubscriberRegistry()
    registry.broadcast(Data("ignored".utf8))
    #expect(registry.isEmpty)
  }
}

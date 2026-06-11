//
//  RoutingIntentStoreTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RoutingIntentStoreTests

/// Covers the persisted routing intent: an unset key reads as on, a saved choice
/// round-trips, and a clear restores the default. Each test uses its own scratch
/// defaults suite so nothing touches the real domain and tests stay independent.
struct RoutingIntentStoreTests {
  // MARK: - Scratch suite

  private func makeScratchDefaults() throws -> UserDefaults {
    let suiteName = "io.goodkind.celltunnel.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  // MARK: - Default is on

  @Test func unsetKeyReadsTrue() throws {
    let defaults = try makeScratchDefaults()
    #expect(RoutingIntentStore.load(from: defaults) == true)
  }

  // MARK: - A saved choice round-trips

  @Test func savedOffRoundTrips() throws {
    let defaults = try makeScratchDefaults()
    RoutingIntentStore.save(false, to: defaults)
    #expect(RoutingIntentStore.load(from: defaults) == false)
  }

  @Test func savedOnRoundTrips() throws {
    let defaults = try makeScratchDefaults()
    RoutingIntentStore.save(false, to: defaults)
    RoutingIntentStore.save(true, to: defaults)
    #expect(RoutingIntentStore.load(from: defaults) == true)
  }

  // MARK: - Clear restores the default

  @Test func clearRestoresDefaultOn() throws {
    let defaults = try makeScratchDefaults()
    RoutingIntentStore.save(false, to: defaults)
    RoutingIntentStore.clear(in: defaults)
    #expect(RoutingIntentStore.load(from: defaults) == true)
  }
}

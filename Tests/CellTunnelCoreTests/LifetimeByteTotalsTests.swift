//
//  LifetimeByteTotalsTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - LifetimeByteTotalsTests

/// Covers the fold that turns a restarting per-session counter into a total that only
/// grows. The session-reset case is what the totals exist for.
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
    // Only one direction restarted. Folding the other would count it twice.
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
    var totals = LifetimeByteTotals(uploadBase: 1_000, downloadBase: 2_000)

    totals.record(upload: 7, download: 9)

    #expect(totals.upload == 1_007)
    #expect(totals.download == 2_009)
  }

  @Test func travelsOnTheWire() throws {
    var totals = LifetimeByteTotals()
    totals.record(upload: 42, download: 84)
    let snapshot = TunnelDaemonStatusSnapshot(lifetimeBytes: totals)

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: encoded)

    #expect(decoded.lifetimeBytes?.upload == 42)
    #expect(decoded.lifetimeBytes?.download == 84)
  }

  /// A producer that predates the field says nothing rather than zero, which a reader
  /// tells apart from a genuine total of zero.
  @Test func absentFromAnOlderProducer() {
    #expect(TunnelDaemonStatusSnapshot().lifetimeBytes == nil)
  }
}

//
//  ThroughputMeterTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - Constants

/// How close two rates must be to count as equal. Rates are computed in floating point,
/// so exact equality would fail on rounding rather than on behaviour.
private let rateTolerance = 0.000001

// MARK: - ThroughputMeterTests

/// Covers the speed a pair of readings implies. The time between them is the point: a
/// meter without it is correct at exactly one spacing and wrong at every other.
struct ThroughputMeterTests {
  @Test func theFirstReadingReportsNothing() {
    var meter = ThroughputMeter()

    let rate = meter.record(uploadBytes: 1_000, downloadBytes: 2_000, at: 10)

    #expect(rate.uploadMegabitsPerSecond == 0)
    #expect(rate.downloadMegabitsPerSecond == 0)
  }

  @Test func oneMegabyteInOneSecondIsEightMegabits() {
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 10)

    let rate = meter.record(uploadBytes: 1_000_000, downloadBytes: 0, at: 11)

    #expect(abs(rate.uploadMegabitsPerSecond - 8) < rateTolerance)
  }

  /// The same traffic over four seconds is a quarter of the speed. A meter that divided
  /// by one reading rather than by the elapsed time reported this four times too fast.
  @Test func fourSecondsApartIsAQuarterTheSpeed() {
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 10)

    let rate = meter.record(uploadBytes: 1_000_000, downloadBytes: 0, at: 14)

    #expect(abs(rate.uploadMegabitsPerSecond - 2) < rateTolerance)
  }

  /// A long gap between readings still reports what moved during it, because the baseline
  /// survives the gap.
  @Test func aPauseStillReportsTheTrafficThatMoved() {
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 10)

    let rate = meter.record(uploadBytes: 30_000_000, downloadBytes: 0, at: 40)

    #expect(abs(rate.uploadMegabitsPerSecond - 8) < rateTolerance)
  }

  /// Subtracting a restarted counter from the old one wraps, which read as an
  /// astronomical speed. Reporting nothing is the truthful answer.
  @Test func aSessionResetReportsNothingRatherThanAHugeSpeed() {
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 5_000_000, downloadBytes: 5_000_000, at: 10)

    let rate = meter.record(uploadBytes: 100, downloadBytes: 100, at: 11)

    #expect(rate.uploadMegabitsPerSecond == 0)
    #expect(rate.downloadMegabitsPerSecond == 0)
  }

  /// No time passed, so no speed can be computed from it.
  @Test func twoReadingsAtTheSameInstantReportNothing() {
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 10)

    let rate = meter.record(uploadBytes: 1_000_000, downloadBytes: 0, at: 10)

    #expect(rate.uploadMegabitsPerSecond == 0)
  }

  /// A reset reseeds rather than only reporting nothing, so the reading after it measures
  /// against the new session instead of against the finished one.
  @Test func theReadingAfterAResetMeasuresTheNewSession() {
    var meter = ThroughputMeter()
    _ = meter.record(uploadBytes: 5_000_000, downloadBytes: 0, at: 10)
    _ = meter.record(uploadBytes: 0, downloadBytes: 0, at: 11)

    let rate = meter.record(uploadBytes: 1_000_000, downloadBytes: 0, at: 12)

    #expect(abs(rate.uploadMegabitsPerSecond - 8) < rateTolerance)
  }
}

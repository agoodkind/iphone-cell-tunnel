//
//  ThroughputCalculator.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - Constants

private let bitsPerByte: Double = 8
private let bitsPerMegabit: Double = 1_000_000

// MARK: - ThroughputCalculator

/// Converts successive relay byte counters into upload and download megabits per
/// second. The poll cadence is one second, so each per-second byte delta is a
/// rate directly. The first reading seeds the baseline and reports zero.
struct ThroughputCalculator {
  private var baseline = TunnelCounters()
  private var hasBaseline = false

  /// Drops the baseline so the next reading seeds afresh.
  mutating func reset() {
    hasBaseline = false
    baseline = TunnelCounters()
  }

  /// The upload and download rate implied by this counter reading against the
  /// previous one.
  mutating func update(
    with counters: TunnelCounters
  ) -> (upload: Double, download: Double) {
    guard hasBaseline else {
      baseline = counters
      hasBaseline = true
      return (0, 0)
    }
    // The relay counts bytes from the Mac's view: `relayBytesIn` arrives at the Mac
    // (download) and `relayBytesOut` leaves the Mac (upload).
    let downloadDelta = counters.relayBytesIn &- baseline.relayBytesIn
    let uploadDelta = counters.relayBytesOut &- baseline.relayBytesOut
    baseline = counters
    let upload = Double(uploadDelta) * bitsPerByte / bitsPerMegabit
    let download = Double(downloadDelta) * bitsPerByte / bitsPerMegabit
    return (upload, download)
  }
}

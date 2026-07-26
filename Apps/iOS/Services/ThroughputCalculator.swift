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

/// Converts successive relay byte totals into upload and download megabits per
/// second. The poll cadence is one second, so each per-second byte delta is a
/// rate directly. The first reading seeds the baseline and reports zero.
///
/// The totals arrive already resolved into user-facing directions, because the
/// relay's two ends count opposite directions under the same names.
struct ThroughputCalculator {
  private var baselineUpload: UInt64 = 0
  private var baselineDownload: UInt64 = 0
  private var hasBaseline = false

  /// Drops the baseline so the next reading seeds afresh.
  mutating func reset() {
    hasBaseline = false
    baselineUpload = 0
    baselineDownload = 0
  }

  /// The upload and download rate implied by these byte totals against the
  /// previous ones.
  mutating func update(
    uploadBytes: UInt64, downloadBytes: UInt64
  ) -> (upload: Double, download: Double) {
    guard hasBaseline else {
      baselineUpload = uploadBytes
      baselineDownload = downloadBytes
      hasBaseline = true
      return (0, 0)
    }
    let uploadDelta = uploadBytes &- baselineUpload
    let downloadDelta = downloadBytes &- baselineDownload
    baselineUpload = uploadBytes
    baselineDownload = downloadBytes
    let upload = Double(uploadDelta) * bitsPerByte / bitsPerMegabit
    let download = Double(downloadDelta) * bitsPerByte / bitsPerMegabit
    return (upload, download)
  }
}

//
//  ThroughputMeter.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-02.
//  Copyright © 2026, all rights reserved.
//

// MARK: - Constants

private let bitsPerByte: Double = 8
private let bitsPerMegabit: Double = 1_000_000

// MARK: - ThroughputMeter

/// Converts successive byte totals into a rate, using the time between them.
///
/// A reading with no timestamp has to assume how long it covers. Assuming one second
/// makes the speed correct at exactly one spacing and wrong at every other, and it makes
/// the figure change when the reading cadence changes rather than when the traffic does.
/// Carrying the time means a reading is right at any spacing, and it lets a gap in
/// readings report the traffic that moved during the gap instead of nothing.
///
/// The totals arrive already resolved into the directions a person reads, because the
/// relay's two ends count opposite directions under the same names.
public struct ThroughputMeter: Equatable, Sendable {
  /// One rate reading, in the unit the screen shows.
  public struct Rate: Equatable, Sendable {
    public let downloadMegabitsPerSecond: Double
    public let uploadMegabitsPerSecond: Double
  }

  private var baselineDownload: UInt64 = 0
  private var baselineTimestamp: Double = 0
  private var baselineUpload: UInt64 = 0
  private var hasBaseline = false

  public init() {
    // Nothing to set up: the first reading becomes the baseline.
  }

  /// The rate these totals imply against the previous ones.
  ///
  /// A reading below the baseline means the session restarted. Subtracting then would
  /// wrap and report an astronomical speed, so it reseeds and reports nothing, which is
  /// the truthful answer about an interval that carried no measurable traffic.
  ///
  /// `timestamp` is seconds on any steady clock; only the difference between two of them
  /// is used.
  public mutating func record(
    uploadBytes: UInt64,
    downloadBytes: UInt64,
    at timestamp: Double
  ) -> Rate {
    let elapsed = timestamp - baselineTimestamp
    let hasMeasurableInterval = hasBaseline && elapsed > 0
    let countersAdvanced = uploadBytes >= baselineUpload && downloadBytes >= baselineDownload
    guard hasMeasurableInterval, countersAdvanced else {
      reseed(uploadBytes: uploadBytes, downloadBytes: downloadBytes, at: timestamp)
      return Rate(downloadMegabitsPerSecond: 0, uploadMegabitsPerSecond: 0)
    }
    let uploadDelta = Double(uploadBytes - baselineUpload)
    let downloadDelta = Double(downloadBytes - baselineDownload)
    reseed(uploadBytes: uploadBytes, downloadBytes: downloadBytes, at: timestamp)
    return Rate(
      downloadMegabitsPerSecond: downloadDelta * bitsPerByte / bitsPerMegabit / elapsed,
      uploadMegabitsPerSecond: uploadDelta * bitsPerByte / bitsPerMegabit / elapsed
    )
  }

  private mutating func reseed(
    uploadBytes: UInt64,
    downloadBytes: UInt64,
    at timestamp: Double
  ) {
    baselineUpload = uploadBytes
    baselineDownload = downloadBytes
    baselineTimestamp = timestamp
    hasBaseline = true
  }
}

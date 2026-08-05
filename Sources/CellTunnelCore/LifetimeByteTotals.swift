//
//  LifetimeByteTotals.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-02.
//  Copyright © 2026, all rights reserved.
//

// MARK: - LifetimeByteTotals

/// Turns a per-session byte counter that restarts at zero into a total that only grows.
///
/// The relay's counters reset whenever a session restarts, so a finished session's last
/// reading has to be folded into a base before the new reading replaces it. Whoever holds
/// this has to see every reading, and the app is closed most of the time, so every byte
/// moved while it was closed was dropped from the total. The daemon runs continuously and
/// is the only party that sees them all.
///
/// The directions are the ones a person reads, resolved by the producer before it calls
/// `record`, because the relay's two ends count opposite directions under the same names.
public struct LifetimeByteTotals: Codable, Equatable, Sendable {
  public var downloadBase: UInt64
  public var lastDownload: UInt64
  public var lastUpload: UInt64
  public var uploadBase: UInt64

  public init() {
    self.init(uploadBase: 0, downloadBase: 0)
  }

  /// Resumes from bases read back from storage, so a daemon restart does not lose what
  /// earlier sessions moved.
  public init(uploadBase: UInt64, downloadBase: UInt64) {
    self.uploadBase = uploadBase
    self.downloadBase = downloadBase
    lastUpload = 0
    lastDownload = 0
  }

  public var upload: UInt64 {
    uploadBase &+ lastUpload
  }

  public var download: UInt64 {
    downloadBase &+ lastDownload
  }

  public var total: UInt64 {
    upload &+ download
  }

  /// Records one reading.
  ///
  /// A reading below the last one means that direction's session restarted, so the
  /// finished session's last reading folds into the base first. Each direction folds on
  /// its own, because a relay can restart one side's counter without the other.
  public mutating func record(upload: UInt64, download: UInt64) {
    if upload < lastUpload {
      uploadBase = uploadBase &+ lastUpload
    }
    if download < lastDownload {
      downloadBase = downloadBase &+ lastDownload
    }
    lastUpload = upload
    lastDownload = download
  }
}

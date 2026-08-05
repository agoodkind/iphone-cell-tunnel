//
//  AgentTunnelController+Lifetime.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Dispatch
import Foundation

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Lifetime byte totals

extension AgentTunnelController {
  /// Folds this reading into the totals and returns them.
  ///
  /// The direction is resolved here, where the producer is known: this Mac counts its own
  /// traffic, so bytes leaving for the server are what a person calls upload and bytes
  /// arriving are download. Doing it here is what lets one stored pair serve both sides of
  /// the relay, which count opposite directions under the same names.
  func recordLifetimeBytes(from counters: TunnelCounters?) -> LifetimeByteTotals {
    let reading = counters ?? TunnelCounters()
    let totals = lifetimeBytes.withLock { existing -> LifetimeByteTotals in
      existing.record(upload: reading.relayBytesOut, download: reading.relayBytesIn)
      return existing
    }
    persistLifetimeBases(totals)
    return totals
  }

  /// Writes the folded bases so a restart resumes rather than starts over.
  private func persistLifetimeBases(_ totals: LifetimeByteTotals) {
    guard let defaults = UserDefaults(suiteName: cellTunnelAppGroupIdentifier) else {
      return
    }
    defaults.set(String(totals.uploadBase), forKey: lifetimeUploadBaseKey)
    defaults.set(String(totals.downloadBase), forKey: lifetimeDownloadBaseKey)
  }

  /// Keeps the byte totals advancing while nobody is asking for status.
  ///
  /// Every other fold happens because a client requested a snapshot. Traffic carried with
  /// no app open would otherwise reach the total only when someone next looked, and a
  /// session that started and ended in that gap would never be counted at all. That is the
  /// defect this exists to close, so the fold has to happen on its own.
  func startLifetimeAccrual() {
    guard lifetimeAccrualTimer == nil else {
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + .seconds(lifetimeAccrualIntervalSeconds),
      repeating: .seconds(lifetimeAccrualIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      Task { await self?.accrueLifetimeBytes() }
    }
    timer.resume()
    lifetimeAccrualTimer = timer
    logger.notice(
      """
      agent lifetime accrual started \
      interval_seconds=\(lifetimeAccrualIntervalSeconds, privacy: .public)
      """
    )
  }

  /// Reads the tunnel's own counters and folds them.
  ///
  /// This goes through the ordinary status read because that is where the counters come
  /// from: the extension reports them, and the fold happens as the reading is assembled.
  /// Nothing runs while no relay is hosted, so an idle Mac pays nothing.
  private func accrueLifetimeBytes() async {
    guard relayHosted else {
      return
    }
    _ = await handleStatus()
  }
}

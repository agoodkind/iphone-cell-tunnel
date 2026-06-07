//
//  RelayThroughputLogger.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-28.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .relay)
private let throughputIntervalSeconds = 1

/// Logs how much the Mac relay counters moved each second, away from the
/// per-datagram path. The timer fires on its own queue, reads the lock-free
/// `RelayMetrics` snapshot, and emits a single structured line when anything
/// changed. State is touched only on that queue.
final class RelayThroughputLogger: @unchecked Sendable {
  private let metrics: RelayMetrics
  private let queue = DispatchQueue(label: "io.goodkind.celltunnel.relayThroughput")
  private var timer: DispatchSourceTimer?
  private var baseline = TunnelCounters()

  init(metrics: RelayMetrics) {
    self.metrics = metrics
  }

  func start() {
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(
      deadline: .now() + .seconds(throughputIntervalSeconds),
      repeating: .seconds(throughputIntervalSeconds)
    )
    source.setEventHandler { [weak self] in
      self?.sampleAndLog()
    }
    self.timer = source
    source.resume()
    logger.notice("mac relay throughput logger started")
  }

  func stop() {
    timer?.cancel()
    timer = nil
    logger.notice("mac relay throughput logger stopped")
  }

  private func sampleAndLog() {
    let snapshot = metrics.snapshot()
    let toServer = snapshot.wireGuardDatagramsToServer &- baseline.wireGuardDatagramsToServer
    let fromServer =
      snapshot.wireGuardDatagramsFromServer &- baseline.wireGuardDatagramsFromServer
    let dropped = snapshot.droppedWireGuardDatagrams &- baseline.droppedWireGuardDatagrams
    let bytesOut = snapshot.relayBytesOut &- baseline.relayBytesOut
    let bytesIn = snapshot.relayBytesIn &- baseline.relayBytesIn
    baseline = snapshot
    if toServer == 0, fromServer == 0, dropped == 0, bytesOut == 0, bytesIn == 0 {
      return
    }
    logger.notice(
      """
      mac relay throughput datagrams_to_server=\(toServer, privacy: .public) \
      datagrams_from_server=\(fromServer, privacy: .public) \
      dropped=\(dropped, privacy: .public) \
      bytes_out=\(bytesOut, privacy: .public) \
      bytes_in=\(bytesIn, privacy: .public)
      """
    )
  }
}

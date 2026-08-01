//
//  AgentTunnelController+Push.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Dispatch
import Foundation

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)
private let statusPushIntervalSeconds = 1

// MARK: - Status pushes

extension AgentTunnelController {
  /// Sends the current status to every client that asked to be told about changes.
  ///
  /// Building the snapshot means reading the running tunnel, so this returns before
  /// doing that when nobody is listening.
  func broadcastStatus() async {
    guard !subscribers.isEmpty else {
      return
    }
    let response = await handleStatus()
    let payload: Data
    do {
      payload = try JSONEncoder().encode(response)
    } catch {
      logger.error(
        """
        agent status push encode failed \
        details=\(String(describing: error), privacy: .public) recovery=skip-push
        """
      )
      return
    }
    subscribers.broadcast(payload)
    logger.debug(
      "agent status pushed bytes=\(payload.count, privacy: .public)"
    )
  }

  /// Starts the repeating push that carries the byte counters.
  ///
  /// Everything else in the snapshot changes at a moment some handler can announce.
  /// The counters advance with every packet and nothing announces them, so they need a
  /// tick. It stops itself once the last client leaves and sends nothing while no relay
  /// is hosted, so an idle app costs nothing.
  func startStatusPushTimer() {
    guard statusPushTimer == nil else {
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + .seconds(statusPushIntervalSeconds),
      repeating: .seconds(statusPushIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      Task { await self?.pushCountersTick() }
    }
    timer.resume()
    statusPushTimer = timer
    logger.notice(
      """
      agent status push timer started \
      interval_seconds=\(statusPushIntervalSeconds, privacy: .public)
      """
    )
  }

  private func pushCountersTick() async {
    guard !subscribers.isEmpty else {
      statusPushTimer?.cancel()
      statusPushTimer = nil
      logger.notice("agent status push timer stopped reason=no-subscribers")
      return
    }
    guard relayHosted else {
      return
    }
    await broadcastStatus()
  }
}

//
//  RelayLivenessMonitor.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Synchronization

private let logger = CellTunnelLog.logger(category: .relay)

/// Watches the loopback socket the extension shares with the agent and reports
/// when the agent stops answering.
///
/// The extension outlives the agent and holds the routes, so an agent that
/// crashed, was force quit, or went away with the login session leaves every
/// captured packet pointed at a relay bridge that no longer exists. The existing
/// counters cannot tell that apart from an idle tunnel, because the outbound
/// counters rise on a fire-and-forget send whether or not anyone is listening, so
/// this sends its own keepalive and waits for the agent's echo.
///
/// The timer runs on its own queue and the liveness state is touched only there,
/// which leaves the provider's stored state under the serialization
/// NetworkExtension gives the tunnel lifecycle callbacks.
final class RelayLivenessMonitor: @unchecked Sendable {
  private let transport: RelayTransport
  private let intervalMilliseconds: Int
  private let queue = DispatchQueue(label: "io.goodkind.celltunnel.relayLiveness")
  // Set from the transport's receive queue and cleared on the timer queue, so it
  // crosses queues and is atomic rather than lock guarded.
  private let sawReply = Atomic<Bool>(false)
  private var liveness: RelayLiveness
  private var timer: DispatchSourceTimer?
  private var isGone = false

  /// Fired once when the agent stops answering, so the caller withdraws routes.
  var onAgentGone: (@Sendable () -> Void)?

  init(transport: RelayTransport, missedRepliesBeforeGone: Int, intervalMilliseconds: Int) {
    self.transport = transport
    self.intervalMilliseconds = intervalMilliseconds
    self.liveness = RelayLiveness(missedRepliesBeforeGone: missedRepliesBeforeGone)
  }

  func start() {
    transport.onKeepaliveReply = { [weak self] in
      self?.sawReply.store(true, ordering: .relaxed)
    }
    // Ask before the first tick judges, so that tick weighs an answer to a
    // keepalive that was actually sent.
    transport.send(RelayHeartbeat.payload)
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(
      deadline: .now() + .milliseconds(intervalMilliseconds),
      repeating: .milliseconds(intervalMilliseconds)
    )
    source.setEventHandler { [weak self] in
      self?.tick()
    }
    timer = source
    source.resume()
    let interval = intervalMilliseconds
    logger.notice(
      "relay liveness monitor started interval_ms=\(interval, privacy: .public)"
    )
  }

  func stop() {
    timer?.cancel()
    timer = nil
    transport.onKeepaliveReply = nil
    logger.notice("relay liveness monitor stopped")
  }

  private func tick() {
    let replied = sawReply.exchange(false, ordering: .relaxed)
    let verdict: RelayLivenessVerdict
    if replied {
      verdict = liveness.recordReply()
    } else {
      verdict = liveness.recordMissedReply()
    }
    switch verdict {
    case .gone:
      isGone = true
      logger.error("relay liveness lost agent recovery=withdraw-routes")
      onAgentGone?()
    case .live:
      isGone = false
      // Routes are not installed here. The agent owns that decision and re-asserts
      // it over the control channel once a phone link is up, so installing on the
      // agent's return would capture traffic with no link to carry it.
      logger.notice("relay liveness regained agent recovery=await-agent-route-state")
    case .unchanged:
      break
    }
    if isGone {
      // A socket that stopped delivering never delivers again, so a fresh one is
      // the only way a returning agent is heard rather than talked at.
      transport.reconnect()
    }
    transport.send(RelayHeartbeat.payload)
  }
}

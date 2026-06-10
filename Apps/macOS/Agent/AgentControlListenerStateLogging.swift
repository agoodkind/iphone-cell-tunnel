//
//  AgentControlListenerStateLogging.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Listener and connection state handling

/// Logs the control listener lifecycle. The listener binds the fixed control
/// port and advertises the Bonjour service the iPhone dials.
func applyListenerState(_ state: NWListener.State) {
  switch state {
  case .ready:
    logger.notice(
      "agent control listener ready port=\(relayControlListenerDefaultPort, privacy: .public)"
    )
  case .failed(let error):
    logger.error(
      "agent control listener failed error=\(error.localizedDescription, privacy: .public)"
    )
  case .cancelled:
    logger.notice("agent control listener cancelled")
  default:
    break
  }
}

/// Logs the accepted connection lifecycle so an iPhone dial that reaches the
/// agent is visible in the log.
func applyAcceptedConnectionState(_ state: NWConnection.State) {
  switch state {
  case .ready:
    logger.notice("agent control connection ready")
  case .waiting(let error):
    logger.error(
      "agent control connection waiting error=\(error.localizedDescription, privacy: .public)"
    )
  case .failed(let error):
    logger.error(
      "agent control connection failed error=\(error.localizedDescription, privacy: .public)"
    )
  case .cancelled:
    logger.notice("agent control connection cancelled")
  default:
    break
  }
}

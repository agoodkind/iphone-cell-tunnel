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

/// Logs whether the Bonjour record the iPhone browses for actually published.
///
/// A listener reaches `.ready` once its socket binds, which says nothing about
/// whether the system accepted the service registration. Those two can disagree:
/// a listener can hold its port while no record is published, and the iPhone then
/// browses forever with no error anywhere. Reporting the registration separately
/// is the only way that state names itself.
func applyServiceRegistrationChange(_ change: NWListener.ServiceRegistrationChange) {
  switch change {
  case .add(let endpoint):
    logger.notice(
      """
      agent control listener service registered \
      endpoint=\(String(describing: endpoint), privacy: .public)
      """
    )
  case .remove(let endpoint):
    logger.notice(
      """
      agent control listener service unregistered \
      endpoint=\(String(describing: endpoint), privacy: .public)
      """
    )
  @unknown default:
    logger.notice("agent control listener service registration changed unknown")
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

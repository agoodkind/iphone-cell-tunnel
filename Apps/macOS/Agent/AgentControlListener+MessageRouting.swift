//
//  AgentControlListener+MessageRouting.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Message routing

extension AgentControlListener {
  /// Decodes one framed message from the status receive loop and routes it: a status
  /// push surfaces its fields, a routing change drives the handler, a public address
  /// updates the exchange, and the rest are logged.
  func handleStreamPayload(_ data: Data) {
    let message: RelayControlMessage
    do {
      message = try RelayControlMessageCodec.decode(data)
    } catch {
      logger.error(
        "agent control decode failed error=\(error.localizedDescription, privacy: .public)"
      )
      return
    }
    switch message {
    case .status(let snapshot):
      logger.notice(
        """
        agent control status hasCellularPath=\(snapshot.hasCellularPath, privacy: .public) \
        interface=\(snapshot.cellularInterface ?? "none", privacy: .public)
        """
      )
      surface(status: snapshot)
    case .error(let failure):
      logger.error(
        """
        agent control error from peer code=\(failure.code, privacy: .public) \
        message=\(failure.message, privacy: .public)
        """
      )
    case .linkInventory(let payload):
      logger.debug(
        """
        agent control received unexpected link-inventory \
        count=\(payload.links.count, privacy: .public)
        """
      )
    case .acknowledge(let payload):
      logger.debug(
        "agent control late ack requestKind=\(payload.requestKind, privacy: .public)"
      )
    case .setServerEndpoint:
      logger.debug("agent control received unexpected set-server-endpoint from peer")
    case .setRoutingEnabled(let payload):
      logger.notice(
        "agent control received routing enabled=\(payload.enabled, privacy: .public)")
      onSetRoutingEnabled?(payload.enabled)
    case .routeState:
      logger.debug("agent control received unexpected route-state from peer")
    case .routingIntent:
      logger.debug("agent control received unexpected routing-intent from peer")
    case .publicAddress(let payload):
      logger.notice(
        """
        agent control received peer public address \
        ipv4=\(payload.addresses.ipv4 ?? "none", privacy: .public) \
        ipv6=\(payload.addresses.ipv6 ?? "none", privacy: .public)
        """
      )
      onPeerPublicAddress?(payload.addresses)
    }
  }
}

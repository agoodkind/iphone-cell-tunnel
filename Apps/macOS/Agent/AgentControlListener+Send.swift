//
//  AgentControlListener+Send.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Handshake and framed send

extension AgentControlListener {
  func sendSetServerEndpoint(on connection: NWConnection) async throws {
    guard let serverEndpoint else {
      throw AgentControlListenerError.connectionFailed("relay endpoint not configured")
    }
    logger.notice(
      """
      agent control sending set-server-endpoint \
      host=\(serverEndpoint.host, privacy: .public) \
      port=\(serverEndpoint.port, privacy: .public)
      """
    )
    let message = RelayControlMessage.setServerEndpoint(
      RelayControlMessage.SetServerEndpoint(endpoint: serverEndpoint)
    )
    try await send(message, on: connection)
  }

  /// Sends the agent's confirmed route state to the selected iPhone, so the app
  /// reports installed routes from the agent's truth rather than the local routing
  /// intent. A no-op when no iPhone is selected.
  func sendRouteState(_ installed: Bool) async {
    guard let selectedConnection else {
      return
    }
    await sendRouteState(installed, on: selectedConnection)
  }

  func sendRouteState(_ installed: Bool, on connection: NWConnection) async {
    do {
      try await send(
        .routeState(RelayControlMessage.RouteState(installed: installed)),
        on: connection
      )
    } catch {
      logger.error(
        """
        agent control route-state send failed installed=\(installed, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public) recovery=await-next-change
        """
      )
    }
  }

  /// Sends the agent's persisted routing intent to the selected iPhone, the value
  /// behind the Route traffic switch, so the phone mirrors the agent's truth instead
  /// of holding its own copy. A no-op when no iPhone is selected.
  func sendRoutingIntent(_ enabled: Bool) async {
    guard let selectedConnection else {
      return
    }
    await sendRoutingIntent(enabled, on: selectedConnection)
  }

  func sendRoutingIntent(_ enabled: Bool, on connection: NWConnection) async {
    do {
      try await send(
        .routingIntent(RelayControlMessage.RoutingIntent(enabled: enabled)),
        on: connection
      )
    } catch {
      logger.error(
        """
        agent control routing-intent send failed enabled=\(enabled, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public) recovery=await-next-change
        """
      )
    }
  }

  func send(
    _ message: RelayControlMessage,
    on connection: NWConnection
  ) async throws {
    let payload = try RelayControlMessageCodec.encode(message)
    let framerMessage = NWProtocolFramer.Message(definition: RelayControlFramer.definition)
    let context = NWConnection.ContentContext(
      identifier: message.kindLabel,
      metadata: [framerMessage]
    )
    let _: Void = try await withCheckedThrowingContinuation { continuation in
      connection.send(
        content: payload,
        contentContext: context,
        isComplete: true,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          continuation.resume()
        }
      )
    }
    logger.notice(
      """
      agent control sent kind=\(message.kindLabel, privacy: .public) \
      bytes=\(payload.count, privacy: .public)
      """
    )
  }

}

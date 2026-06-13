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
    logger.notice(
      """
      agent control sending set-server-endpoint \
      host=\(self.serverEndpoint.host, privacy: .public) \
      port=\(self.serverEndpoint.port, privacy: .public)
      """
    )
    let message = RelayControlMessage.setServerEndpoint(
      RelayControlMessage.SetServerEndpoint(endpoint: serverEndpoint)
    )
    try await send(message, on: connection)
    try await awaitAcknowledge(on: connection, requestKind: "set-server-endpoint")
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

  func awaitAcknowledge(
    on connection: NWConnection,
    requestKind: String
  ) async throws {
    let received = try await receiveOne(on: connection)
    switch received {
    case .acknowledge(let payload) where payload.requestKind == requestKind:
      logger.notice(
        """
        agent control acknowledge received \
        requestKind=\(payload.requestKind, privacy: .public)
        """
      )
    case .error(let failure):
      throw AgentControlListenerError.remoteError(
        AgentControlListenerError.RemoteErrorPayload(
          code: failure.code,
          message: failure.message
        )
      )
    case .status(let snapshot):
      // A status arriving before the ack is consumed and its ack awaited again. The
      // device name it carries is applied from the status receive loop instead, once
      // this connection is in the roster, so a pre-ack status is not attributed here.
      logger.notice(
        """
        agent control received status before ack \
        hasCellularPath=\(snapshot.hasCellularPath, privacy: .public)
        """
      )
      try await awaitAcknowledge(on: connection, requestKind: requestKind)
    case .publicAddress(let payload):
      onPeerPublicAddress?(payload.addresses)
      try await awaitAcknowledge(on: connection, requestKind: requestKind)
    default:
      throw AgentControlListenerError.acknowledgeMissing
    }
  }

  func receiveOne(on connection: NWConnection) async throws -> RelayControlMessage {
    try await withCheckedThrowingContinuation { continuation in
      connection.receiveMessage { data, _, _, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let data, !data.isEmpty else {
          continuation.resume(
            throwing: AgentControlListenerError.connectionFailed(
              "empty payload received"
            )
          )
          return
        }
        do {
          let decoded = try RelayControlMessageCodec.decode(data)
          continuation.resume(returning: decoded)
        } catch {
          logger.error(
            """
            agent control decode failed during receive \
            error=\(error.localizedDescription, privacy: .public)
            """
          )
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

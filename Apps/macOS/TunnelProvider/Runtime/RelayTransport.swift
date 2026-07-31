//
//  RelayTransport.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

enum RelayTransportError: LocalizedError {
  case alreadyConnected
  case invalidEndpoint
  case notConnected

  var errorDescription: String? {
    switch self {
    case .alreadyConnected:
      return "relay transport already connected"
    case .invalidEndpoint:
      return "relay transport endpoint invalid"
    case .notConnected:
      return "relay transport not connected"
    }
  }
}

// MARK: - RelayTransport

final class RelayTransport: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.goodkind.celltunnel.relay")
  private let metrics: RelayMetrics
  // The liveness monitor replaces the connection from its own queue while
  // WireGuard sends on another, so both sides take this lock. An uncontended lock
  // costs far less than the datagram send it guards.
  private let stateLock = NSLock()
  private var connection: NWConnection?
  private var endpoint: NWEndpoint?
  var onReceive: ((Data) -> Void)?
  /// Called when the agent echoes the liveness keepalive.
  var onKeepaliveReply: (() -> Void)?

  init(metrics: RelayMetrics) {
    self.metrics = metrics
  }

  func connect(to endpoint: NWEndpoint) throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard connection == nil else {
      throw RelayTransportError.alreadyConnected
    }
    self.endpoint = endpoint
    startLocked(to: endpoint)
  }

  /// Drops the socket and dials the same endpoint again.
  ///
  /// The agent hosts the listener on the other end, so an agent that died takes
  /// the flow with it and leaves this connection failed on the ICMP unreachable
  /// its own sends provoke. A failed connection never recovers on its own, so the
  /// liveness monitor redials while it believes the agent is gone and a restarted
  /// agent is found again instead of being talked at through a dead socket.
  func reconnect() {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let endpoint else {
      return
    }
    connection?.cancel()
    connection = nil
    startLocked(to: endpoint)
  }

  func send(_ datagram: Data) {
    stateLock.lock()
    let activeConnection = connection
    stateLock.unlock()
    guard let activeConnection else {
      metrics.addDropped()
      logger.error(
        """
        relay transport send failed error=not-connected \
        bytes=\(datagram.count, privacy: .public)
        """
      )
      return
    }
    let relayMetrics = self.metrics
    activeConnection.send(
      content: datagram,
      completion: .contentProcessed { error in
        guard let error else {
          return
        }
        relayMetrics.addDropped()
        logger.error(
          """
          relay transport send failed \
          error=\(error.localizedDescription, privacy: .public)
          """
        )
      }
    )
  }

  func disconnect() {
    stateLock.lock()
    let activeConnection = connection
    connection = nil
    // Forgetting the endpoint is what stops a redial from resurrecting the socket
    // after the tunnel has stopped.
    endpoint = nil
    stateLock.unlock()
    guard let activeConnection else {
      return
    }
    activeConnection.cancel()
    logger.notice("relay transport disconnected")
  }

  private func startLocked(to endpoint: NWEndpoint) {
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true
    let nwConnection = NWConnection(to: endpoint, using: parameters)
    nwConnection.stateUpdateHandler = { state in
      switch state {
      case .waiting(let error):
        logger.error(
          """
          relay transport waiting error=\(error.localizedDescription, privacy: .public) \
          endpoint=\(String(describing: endpoint), privacy: .public)
          """
        )
      case .failed(let error):
        logger.error(
          """
          relay transport failed error=\(error.localizedDescription, privacy: .public) \
          endpoint=\(String(describing: endpoint), privacy: .public)
          """
        )
      default:
        logger.notice(
          """
          relay transport state=\(String(describing: state), privacy: .public) \
          endpoint=\(String(describing: endpoint), privacy: .public)
          """
        )
      }
    }
    nwConnection.start(queue: queue)
    connection = nwConnection
    receiveLoop(on: nwConnection)
    logger.notice(
      "relay transport connecting endpoint=\(String(describing: endpoint), privacy: .public)"
    )
  }

  private func receiveLoop(on activeConnection: NWConnection) {
    activeConnection.receiveMessage { [weak self] data, _, _, error in
      guard let self else {
        return
      }
      if let data, !data.isEmpty {
        deliver(data)
      }
      if let error {
        logger.error(
          "relay transport receive failed error=\(error.localizedDescription, privacy: .public)"
        )
        // A receive error ends delivery on this socket for good, so the loop stops
        // and the liveness monitor dials again. Measured on loopback: after the
        // first error every further receive returns the same error immediately
        // while the connection still reports itself ready, and a datagram the peer
        // really sent afterwards never arrives. Re-arming therefore recovers
        // nothing and spins a core inside the extension, while a fresh connection
        // to the same endpoint delivers again.
        return
      }
      receiveLoop(on: activeConnection)
    }
  }

  // The agent answers the liveness keepalive on this same socket, so the echo is
  // taken here rather than injected into WireGuard, which would be handed a
  // one-byte datagram it cannot parse and would count it as relay traffic.
  private func deliver(_ datagram: Data) {
    if RelayHeartbeat.isHeartbeat(datagram) {
      onKeepaliveReply?()
      return
    }
    guard let onReceive else {
      metrics.addDropped()
      return
    }
    onReceive(datagram)
  }
}

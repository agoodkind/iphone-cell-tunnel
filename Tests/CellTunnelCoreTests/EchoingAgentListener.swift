//
//  EchoingAgentListener.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Network

/// The byte the traffic payload repeats. It is not the heartbeat byte, so a
/// delivered payload is never mistaken for a keepalive echo.
private let trafficByte: UInt8 = 0xAB

/// The traffic payload length, well past the one-byte heartbeat so the transport
/// treats what arrives as relay traffic.
private let trafficByteCount = 64

/// The byte that asks for a zero length reply, which is how a test puts a socket
/// into the state the transport has to survive.
private let deafenByte: UInt8 = 0xEE

// MARK: - EchoingAgentListener

/// A stand-in for the agent's relay bridge, bound to an ephemeral loopback port.
///
/// The tests need a real socket on the other end of `RelayTransport`, because the
/// behavior under test is what the extension does when its peer stops answering,
/// and that is a property of the socket rather than of any object it holds.
/// Cancelling this listener is how a test makes the agent go away.
final class EchoingAgentListener: @unchecked Sendable {
  /// What the stand-in sends back for each datagram it receives.
  enum ReplyMode {
    /// Relay traffic, except that a datagram asking to be deafened is answered
    /// with a zero length datagram.
    case traffic
    /// The heartbeat echo the real agent answers the extension's keepalive with.
    case heartbeat
  }

  /// The traffic payload, sized well past the one-byte heartbeat so the transport
  /// treats it as relay traffic rather than as a keepalive reply.
  static let trafficPayload = Data(repeating: trafficByte, count: trafficByteCount)

  /// Asks the stand-in for a zero length reply, which ends delivery on the asking
  /// connection. Real relay traffic never carries this shape, so it exists only to
  /// put the socket into the state the transport has to survive.
  static let deafenRequest = Data([deafenByte])

  private let mode: ReplyMode
  private let queue = DispatchQueue(label: "io.goodkind.celltunnel.test.echoAgent")
  private var listener: NWListener?
  private var connections: [NWConnection] = []

  init(mode: ReplyMode) {
    self.mode = mode
  }

  /// Binds an ephemeral UDP port and returns it once the listener is ready, so a
  /// test dials a port that is certainly open.
  func start() async throws -> NWEndpoint.Port {
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    let nwListener = try NWListener(using: parameters, on: .any)
    listener = nwListener
    nwListener.newConnectionHandler = { [weak self] connection in
      self?.adopt(connection)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let box = ListenerReadyBox(continuation)
      nwListener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          box.resume(returning: nwListener.port ?? .any)
        case .failed(let error):
          box.resume(throwing: error)
        default:
          break
        }
      }
      nwListener.start(queue: queue)
    }
  }

  /// Stops answering, which is what the extension sees when the agent dies.
  func stop() {
    queue.sync {
      for connection in connections {
        connection.cancel()
      }
      connections = []
      listener?.cancel()
      listener = nil
    }
  }

  private func adopt(_ connection: NWConnection) {
    connections.append(connection)
    connection.start(queue: queue)
    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self else {
        return
      }
      if let data, !data.isEmpty, error == nil {
        reply(to: data, on: connection)
      }
      guard error == nil else {
        return
      }
      receive(on: connection)
    }
  }

  private func reply(to request: Data, on connection: NWConnection) {
    switch mode {
    case .traffic:
      if request == Self.deafenRequest {
        connection.send(content: Data(), completion: .idempotent)
        return
      }
      connection.send(content: Self.trafficPayload, completion: .idempotent)
    case .heartbeat:
      connection.send(content: RelayHeartbeat.payload, completion: .idempotent)
    }
  }
}

// MARK: - ListenerReadyBox

/// Guards the listener's readiness continuation, because a Network listener can
/// report a state more than once and resuming a continuation twice traps.
private final class ListenerReadyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<NWEndpoint.Port, Error>?

  init(_ continuation: CheckedContinuation<NWEndpoint.Port, Error>) {
    self.continuation = continuation
  }

  func resume(returning port: NWEndpoint.Port) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(returning: port)
  }

  func resume(throwing error: Error) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(throwing: error)
  }
}

// MARK: - ReceivedDatagrams

/// Collects what the transport delivered, since the delivery closure runs on the
/// transport's receive queue and the test reads it from the main actor.
final class ReceivedDatagrams: @unchecked Sendable {
  private let lock = NSLock()
  private var datagrams: [Data] = []

  func append(_ datagram: Data) {
    lock.lock()
    defer { lock.unlock() }
    datagrams.append(datagram)
  }

  func countOf(_ datagram: Data) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return datagrams.filter { $0 == datagram }.count
  }
}

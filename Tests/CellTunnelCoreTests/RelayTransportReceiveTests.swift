//
//  RelayTransportReceiveTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Network
import Testing

@testable import CellTunnelTunnelRuntime

@MainActor
@Suite("Relay transport receive")
struct RelayTransportReceiveTests {
  /// Dialing again is what restores delivery after the socket stops delivering.
  ///
  /// A receive error ends delivery on that socket permanently: every later receive
  /// returns the same error at once while the connection still reports itself
  /// ready, and a datagram the peer really sent afterwards never arrives. The
  /// extension therefore recovers by replacing the connection, which is what the
  /// liveness monitor asks for once it decides the agent is gone.
  @Test("dialing again restores delivery after the socket stops delivering")
  func dialingAgainRestoresDelivery() async throws {
    let agent = EchoingAgentListener(mode: .traffic)
    let port = try await agent.start()
    let transport = RelayTransport(metrics: RelayMetrics())
    let received = ReceivedDatagrams()
    transport.onReceive = { datagram in
      received.append(datagram)
    }
    try transport.connect(to: .hostPort(host: "127.0.0.1", port: port))

    transport.send(Data(repeating: 0x01, count: 32))
    let deliveredFirst = try await waitFor(received, count: 1)

    transport.send(EchoingAgentListener.deafenRequest)
    try await Task.sleep(for: .milliseconds(400))
    transport.send(Data(repeating: 0x02, count: 32))
    let deliveredWhileDeaf = try await waitFor(received, count: 2)

    transport.reconnect()
    transport.send(Data(repeating: 0x03, count: 32))
    let deliveredAfterDialingAgain = try await waitFor(received, count: 2)

    transport.disconnect()
    agent.stop()

    #expect(deliveredFirst)
    #expect(!deliveredWhileDeaf)
    #expect(deliveredAfterDialingAgain)
  }

  /// A keepalive echo is taken by the transport rather than handed on as traffic,
  /// because WireGuard cannot parse a one-byte datagram and would count it as
  /// relay traffic.
  @Test("a keepalive echo is reported as a reply, not as traffic")
  func keepaliveEchoIsReportedAsAReply() async throws {
    let agent = EchoingAgentListener(mode: .heartbeat)
    let port = try await agent.start()
    let transport = RelayTransport(metrics: RelayMetrics())
    let received = ReceivedDatagrams()
    let replies = ReplyCounter()
    transport.onReceive = { datagram in
      received.append(datagram)
    }
    transport.onKeepaliveReply = {
      replies.increment()
    }
    try transport.connect(to: .hostPort(host: "127.0.0.1", port: port))

    transport.send(RelayHeartbeat.payload)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, !replies.sawReply {
      try await Task.sleep(for: .milliseconds(20))
    }
    let sawReply = replies.sawReply
    let trafficCount = received.countOf(RelayHeartbeat.payload)

    transport.disconnect()
    agent.stop()

    #expect(sawReply)
    #expect(trafficCount == 0)
  }

  /// Polls until the count is reached, so a real socket decides the timing rather
  /// than a fixed sleep long enough to be slow and short enough to be flaky.
  private func waitFor(_ box: ReceivedDatagrams, count: Int) async throws -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if box.countOf(EchoingAgentListener.trafficPayload) >= count {
        return true
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    return box.countOf(EchoingAgentListener.trafficPayload) >= count
  }
}

// MARK: - ReplyCounter

/// Counts keepalive echoes, since the transport reports them from its receive queue.
final class ReplyCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var replies = 0

  /// Whether the transport has reported at least one keepalive echo.
  var sawReply: Bool {
    lock.lock()
    defer { lock.unlock() }
    return replies > 0
  }

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    replies += 1
  }
}

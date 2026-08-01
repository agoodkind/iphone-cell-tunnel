//
//  AgentPushDeliveryTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Synchronization
import Testing

@testable import CellTunnelCore

@Suite("Agent push delivery")
struct AgentPushDeliveryTests {
  private func encodedPush(running: Bool) throws -> Data {
    let snapshot = TunnelDaemonStatusSnapshot(running: running)
    return try JSONEncoder().encode(AgentControlResponse(status: snapshot))
  }

  @Test("a pushed payload reaches the consumer as a snapshot")
  func pushedPayloadReachesConsumer() throws {
    let delivery = AgentPushDelivery()
    let received = Mutex<[Bool]>([])
    delivery.setHandlers(
      onSnapshot: { snapshot in
        received.withLock { $0.append(snapshot.running) }
      },
      onDisconnect: {
        // This test is about snapshots, so the disconnect is not exercised.
      }
    )

    delivery.deliver(payload: try encodedPush(running: true))
    delivery.deliver(payload: try encodedPush(running: false))

    #expect(received.withLock { $0 } == [true, false])
  }

  /// The transport hands over whatever arrived, so a message with no payload and one
  /// that is not a response both reach here. Neither says anything about the tunnel,
  /// and passing either on would replace a good reading on screen with a false one.
  @Test("a payload that carries no snapshot is ignored")
  func payloadWithoutSnapshotIsIgnored() throws {
    let delivery = AgentPushDelivery()
    let count = Mutex(0)
    delivery.setHandlers(
      onSnapshot: { _ in
        count.withLock { $0 += 1 }
      },
      onDisconnect: {
        // This test is about snapshots, so the disconnect is not exercised.
      }
    )

    delivery.deliver(payload: nil)
    delivery.deliver(payload: Data("not json".utf8))
    delivery.deliver(payload: try JSONEncoder().encode(AgentControlResponse()))

    #expect(count.withLock { $0 } == 0)
  }

  /// Cancelling locally and hearing the peer is gone are two notices of one disconnect,
  /// and a consumer that hears it twice would tear down a subscription it had already
  /// replaced.
  @Test("a disconnect is reported once")
  func disconnectIsReportedOnce() {
    let delivery = AgentPushDelivery()
    let count = Mutex(0)
    delivery.setHandlers(
      onSnapshot: { _ in
        // This test is about the disconnect, so snapshots are not exercised.
      },
      onDisconnect: {
        count.withLock { $0 += 1 }
      }
    )

    delivery.reportDisconnected()
    delivery.reportDisconnected()

    #expect(count.withLock { $0 } == 1)
  }

  @Test("a snapshot after a disconnect is dropped")
  func snapshotAfterDisconnectIsDropped() throws {
    let delivery = AgentPushDelivery()
    let count = Mutex(0)
    delivery.setHandlers(
      onSnapshot: { _ in
        count.withLock { $0 += 1 }
      },
      onDisconnect: {
        // This test is about snapshots, so the disconnect is not exercised.
      }
    )

    delivery.reportDisconnected()
    delivery.deliver(payload: try encodedPush(running: true))

    #expect(count.withLock { $0 } == 0)
  }
}

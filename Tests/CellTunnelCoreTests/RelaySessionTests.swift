//
//  RelaySessionTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-12.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RelaySessionTests

/// Covers the relay-session token wire message and the adoption-prime framing
/// that binds relay-link admission to the promoted control session.
struct RelaySessionTests {
  // MARK: - Prime framing

  @Test func primeRoundTripsSessionID() {
    let sessionID: UInt64 = 0x0123_4567_89ab_cdef
    let data = RelaySessionPrime.payload(sessionID: sessionID)

    #expect(RelaySessionPrime.sessionID(from: data) == sessionID)
  }

  @Test func primeRoundTripsExtremeSessionIDs() {
    for sessionID in [UInt64.min, UInt64.max, 1] {
      let data = RelaySessionPrime.payload(sessionID: sessionID)
      #expect(RelaySessionPrime.sessionID(from: data) == sessionID)
    }
  }

  @Test func heartbeatIsNotAPrime() {
    #expect(RelaySessionPrime.sessionID(from: RelayHeartbeat.payload) == nil)
  }

  @Test func wireGuardSizedPayloadIsNotAPrime() {
    // A WireGuard datagram is far larger than the nine-byte prime, so it must
    // never decode as a session prime and therefore never admit a link.
    let wireGuardSized = Data(repeating: 0x01, count: 64)

    #expect(RelaySessionPrime.sessionID(from: wireGuardSized) == nil)
  }

  @Test func wrongLengthFrameIsNotAPrime() {
    // The tag byte alone, with no id, is not a valid prime.
    #expect(RelaySessionPrime.sessionID(from: Data([0x01])) == nil)
  }

  // MARK: - Control message coding

  @Test func relaySessionRoundTripsAndLabelsKind() throws {
    let message = RelayControlMessage.relaySession(
      RelayControlMessage.RelaySession(sessionID: 0xdead_beef)
    )

    let encoded = try RelayControlMessageCodec.encode(message)
    let decoded = try RelayControlMessageCodec.decode(encoded)

    #expect(decoded.kindLabel == "relay-session")
    guard case .relaySession(let session) = decoded else {
      Issue.record("unexpected message: \(decoded)")
      return
    }
    #expect(session.sessionID == 0xdead_beef)
  }
}

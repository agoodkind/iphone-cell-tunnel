//
//  AgentControlSubscribeTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import CellTunnelCore

@Suite("Agent control subscribe request")
struct AgentControlSubscribeTests {
  /// The request enum is hand written, so a case added without both coding arms
  /// encodes or decodes into something else. A round trip is what catches that.
  @Test("a subscribe request survives the round trip")
  func subscribeSurvivesRoundTrip() throws {
    let encoded = try JSONEncoder().encode(AgentControlEnvelope(request: .subscribe))
    let decoded = try JSONDecoder().decode(AgentControlEnvelope.self, from: encoded)

    guard case .subscribe = decoded.request else {
      Issue.record("decoded \(decoded.request) instead of subscribe")
      return
    }
    #expect(decoded.version == agentControlWireVersion)
  }

  /// The discriminator is the wire contract: a client of any version reads this field
  /// to know what the message is, so it is asserted by name rather than by shape.
  @Test("subscribe travels under the kind discriminator")
  func subscribeTravelsUnderKind() throws {
    let encoded = try JSONEncoder().encode(AgentControlEnvelope(request: .subscribe))
    let envelope = try JSONDecoder().decode(EnvelopeShape.self, from: encoded)

    #expect(envelope.request.kind == "subscribe")
  }

  /// Reads only the discriminator, so the assertion is about the wire contract rather
  /// than about how the request type happens to be written today.
  private struct EnvelopeShape: Decodable {
    struct RequestShape: Decodable {
      let kind: String
    }

    let request: RequestShape
  }

  /// Telling subscribers after a read would push a snapshot the asking client already
  /// has, and would make every status request cost a second status read.
  @Test("reads do not count as state changes")
  func readsDoNotCountAsStateChanges() {
    #expect(AgentControlRequest.status.mutatesState == false)
    #expect(AgentControlRequest.subscribe.mutatesState == false)
    #expect(AgentControlRequest.check.mutatesState == false)
    #expect(AgentControlRequest.listRelayServices.mutatesState == false)
    #expect(AgentControlRequest.getConfigText(id: UUID()).mutatesState == false)
  }

  @Test("changes count as state changes")
  func changesCountAsStateChanges() {
    #expect(AgentControlRequest.setRoutingEnabled(enabled: true).mutatesState)
    #expect(AgentControlRequest.reset.mutatesState)
    #expect(AgentControlRequest.deleteConfig(id: UUID()).mutatesState)
    #expect(AgentControlRequest.selectEgressPeer(peerID: "peer").mutatesState)
  }
}

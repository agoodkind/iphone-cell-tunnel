//
//  StatusSnapshotRoutingFieldsTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - StatusSnapshotRoutingFieldsTests

/// Covers the snapshot's routing-intent and link-set fields: they round-trip
/// through the wire encoding, and a payload from an old producer that lacks them
/// decodes with both reading nil, so mixed-version peers stay compatible.
struct StatusSnapshotRoutingFieldsTests {
  // MARK: - New fields round-trip

  @Test func routingFieldsRoundTrip() throws {
    let snapshot = TunnelDaemonStatusSnapshot(
      running: true,
      routeState: .installed,
      routingIntentEnabled: .on,
      agentLinks: [
        AgentLinkStatus(interfaceName: "en11", linkClass: .wired, isCarrying: true),
        AgentLinkStatus(interfaceName: "en0", linkClass: .wifiLan, isCarrying: false),
      ]
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: data)

    #expect(decoded.routingIntentEnabled == .on)
    #expect(decoded.agentLinks?.count == 2)
    #expect(decoded.agentLinks?.first?.interfaceName == "en11")
    #expect(decoded.agentLinks?.first?.isCarrying == true)
    #expect(decoded.agentLinks?.last?.linkClass == .wifiLan)
  }

  // MARK: - Old payloads stay decodable

  @Test func oldPayloadWithoutRoutingFieldsDecodesNil() throws {
    // A producer that predates the routing fields encodes a payload without
    // them; decoding must read both as nil rather than failing.
    let oldPayload = """
      {
        "running": true,
        "routeState": "installed",
        "peerState": "not-selected",
        "ipv4Address": "",
        "ipv6Address": "",
        "discovery": {"phase": "browsing", "services": []}
      }
      """
    let data = try #require(oldPayload.data(using: .utf8))

    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: data)

    #expect(decoded.routingIntentEnabled == nil)
    #expect(decoded.agentLinks == nil)
    #expect(decoded.routeState == .installed)
  }

  // MARK: - Renderer carries the new lines and keeps old keys

  @Test func renderedOutputCarriesIntentAndLinks() {
    let snapshot = TunnelDaemonStatusSnapshot(
      running: true,
      routeState: .installed,
      routingIntentEnabled: .on,
      agentLinks: [
        AgentLinkStatus(interfaceName: "en11", linkClass: .wired, isCarrying: true)
      ]
    )
    let output = snapshot.renderedOutput

    #expect(output.contains("routes=installed"))
    #expect(output.contains("routing_intent=on"))
    #expect(output.contains("links=1"))
    #expect(output.contains("link.en11=wired carrying"))
  }
}

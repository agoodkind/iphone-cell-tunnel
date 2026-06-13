//
//  ConnectedPeerRosterTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - ConnectedPeerRosterTests

/// Covers the connected-iPhone roster the Mac selector reads: the `ConnectedPeer`
/// roster round-trips in the status snapshot, an old payload without it decodes nil,
/// the renderer carries the roster lines, and the `selectEgressPeer` control request
/// round-trips through its envelope.
struct ConnectedPeerRosterTests {
  // MARK: - Roster round-trip

  @Test func connectedPeersRoundTripInSnapshot() throws {
    let snapshot = TunnelDaemonStatusSnapshot(
      running: true,
      connectedPeers: [
        ConnectedPeer(id: "1", name: "Alex iPhone", isSelected: true),
        ConnectedPeer(id: "2", name: "Test iPhone", isSelected: false),
      ]
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: data)

    #expect(decoded.connectedPeers?.count == 2)
    #expect(decoded.connectedPeers?.first?.id == "1")
    #expect(decoded.connectedPeers?.first?.name == "Alex iPhone")
    #expect(decoded.connectedPeers?.first?.isSelected == true)
    #expect(decoded.connectedPeers?.last?.isSelected == false)
  }

  // MARK: - Old payloads stay decodable

  @Test func oldPayloadWithoutRosterDecodesNil() throws {
    let oldPayload = """
      {
        "running": true,
        "routeState": "not-installed",
        "peerState": "not-selected",
        "ipv4Address": "",
        "ipv6Address": "",
        "discovery": {"phase": "browsing", "services": []}
      }
      """
    let data = try #require(oldPayload.data(using: .utf8))

    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: data)

    #expect(decoded.connectedPeers == nil)
  }

  // MARK: - Renderer carries the roster

  @Test func renderedOutputCarriesRoster() {
    let snapshot = TunnelDaemonStatusSnapshot(
      running: true,
      connectedPeers: [
        ConnectedPeer(id: "7", name: "Alex iPhone", isSelected: true),
        ConnectedPeer(id: "8", name: "Test iPhone", isSelected: false),
      ]
    )
    let output = snapshot.renderedOutput

    #expect(output.contains("peers=2"))
    #expect(output.contains("peer.7=Alex iPhone selected"))
    #expect(output.contains("peer.8=Test iPhone"))
  }

  // MARK: - select-egress request round-trip

  @Test func selectEgressPeerRequestRoundTripsThroughEnvelope() throws {
    let envelope = AgentControlEnvelope(request: .selectEgressPeer(peerID: "42"))
    let encoded = try JSONEncoder().encode(envelope)

    let decoded = try JSONDecoder().decode(AgentControlEnvelope.self, from: encoded)

    guard case .selectEgressPeer(let peerID) = decoded.request else {
      Issue.record("unexpected request: \(decoded.request)")
      return
    }
    #expect(peerID == "42")
  }
}

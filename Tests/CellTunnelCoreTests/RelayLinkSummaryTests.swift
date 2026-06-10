//
//  RelayLinkSummaryTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RelayLinkSummaryTests

struct RelayLinkSummaryTests {
  // MARK: - Preference sorting

  @Test func preferenceSortedOrdersBestLinkFirst() {
    let sorted = RelayLinkSummary.preferenceSorted([
      RelayLinkSummary(interfaceName: "awdl0", linkClass: .peerToPeer),
      RelayLinkSummary(interfaceName: "en0", linkClass: .wifiLan),
      RelayLinkSummary(interfaceName: "en2", linkClass: .wired),
    ])

    #expect(sorted.map(\.interfaceName) == ["en2", "en0", "awdl0"])
  }

  @Test func preferenceSortedBreaksTiesByInterfaceName() {
    let sorted = RelayLinkSummary.preferenceSorted([
      RelayLinkSummary(interfaceName: "en5", linkClass: .wifiLan),
      RelayLinkSummary(interfaceName: "en0", linkClass: .wifiLan),
    ])

    #expect(sorted.map(\.interfaceName) == ["en0", "en5"])
  }

  // MARK: - Status snapshot coding

  @Test func statusSnapshotRoundTripsAvailableLinks() throws {
    let localLinks = [
      RelayLinkSummary(interfaceName: "en0", linkClass: .wifiLan)
    ]
    let peerLinks = [
      RelayLinkSummary(interfaceName: "awdl0", linkClass: .peerToPeer)
    ]
    let snapshot = TunnelDaemonStatusSnapshot(
      localAvailableLinks: localLinks,
      peerAvailableLinks: peerLinks
    )

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(
      TunnelDaemonStatusSnapshot.self,
      from: encoded
    )

    #expect(decoded == snapshot)
  }

  @Test func statusSnapshotDecodesOldPayloadWithoutAvailableLinks() throws {
    let json = """
      {
        "running": false,
        "routeState": "not-installed",
        "peerState": "not-selected",
        "ipv4Address": "",
        "ipv6Address": "",
        "discovery": {
          "phase": "stopped",
          "services": []
        }
      }
      """

    let decoded = try JSONDecoder().decode(
      TunnelDaemonStatusSnapshot.self,
      from: Data(json.utf8)
    )

    #expect(decoded.localAvailableLinks == nil)
    #expect(decoded.peerAvailableLinks == nil)
  }

  // MARK: - Relay control coding

  @Test func statusMessageRoundTripsAvailableLinks() throws {
    let links = [
      RelayLinkSummary(interfaceName: "en2", linkClass: .wired)
    ]
    let message = RelayControlMessage.status(
      RelayControlMessage.Status(
        hasCellularPath: true,
        availableLinks: links
      )
    )

    let decoded = try relayControlRoundTrip(message)

    guard case .status(let status) = decoded else {
      Issue.record("unexpected message: \(decoded)")
      return
    }
    #expect(status.availableLinks == links)
  }

  @Test func statusMessageDecodesOldPayloadWithoutAvailableLinks() throws {
    let json = """
      {
        "status": {
          "_0": {
            "version": \(relayControlWireVersion),
            "hasCellularPath": false
          }
        }
      }
      """

    let decoded = try RelayControlMessageCodec.decode(Data(json.utf8))

    guard case .status(let status) = decoded else {
      Issue.record("unexpected message: \(decoded)")
      return
    }
    #expect(status.availableLinks == nil)
  }

  @Test func linkInventoryRoundTripsAndLabelsKind() throws {
    let links = [
      RelayLinkSummary(interfaceName: "en2", linkClass: .wired),
      RelayLinkSummary(interfaceName: "en0", linkClass: .wifiLan),
    ]
    let message = RelayControlMessage.linkInventory(
      RelayControlMessage.LinkInventory(links: links)
    )

    let decoded = try relayControlRoundTrip(message)

    #expect(decoded.kindLabel == "link-inventory")
    guard case .linkInventory(let inventory) = decoded else {
      Issue.record("unexpected message: \(decoded)")
      return
    }
    #expect(inventory.links == links)
  }
}

private func relayControlRoundTrip(
  _ message: RelayControlMessage
) throws -> RelayControlMessage {
  let encoded = try RelayControlMessageCodec.encode(message)
  return try RelayControlMessageCodec.decode(encoded)
}

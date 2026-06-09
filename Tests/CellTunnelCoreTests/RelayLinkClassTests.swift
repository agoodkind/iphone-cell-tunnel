//
//  RelayLinkClassTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Network
import Testing

// MARK: - RelayLinkClassTests

/// Covers the interface-to-class mapping, focusing on the AWDL interface that can
/// surface as `.wifi` or `.other`. The name prefix must win over the type so AWDL
/// never ties the Wi-Fi LAN link in the carrying chooser.
struct RelayLinkClassTests {
  // MARK: - AWDL name wins over type

  @Test func awdlClassesPeerToPeerWhenTypeIsWifi() {
    #expect(RelayLinkClass.classify(name: "awdl0", type: .wifi) == .peerToPeer)
  }

  @Test func awdlClassesPeerToPeerWhenTypeIsOther() {
    #expect(RelayLinkClass.classify(name: "awdl0", type: .other) == .peerToPeer)
  }

  // MARK: - Non-AWDL interfaces classify by type

  @Test func wifiLanInterfaceClassesWifiLan() {
    #expect(RelayLinkClass.classify(name: "en0", type: .wifi) == .wifiLan)
  }

  @Test func wiredInterfaceClassesWired() {
    #expect(RelayLinkClass.classify(name: "en5", type: .wiredEthernet) == .wired)
  }

  @Test func usbOtherInterfaceClassesWired() {
    // USB CDC-NCM Ethernet surfaces as `.other` with a non-AWDL name.
    #expect(RelayLinkClass.classify(name: "en9", type: .other) == .wired)
  }

  // MARK: - Name-only fallback

  @Test func nameOnlyAwdlIsPeerToPeer() {
    #expect(RelayLinkClass.forInterfaceName("awdl0") == .peerToPeer)
  }

  @Test func nameOnlyNonAwdlIsWired() {
    #expect(RelayLinkClass.forInterfaceName("en0") == .wired)
  }

  // MARK: - Chooser picks Wi-Fi LAN over AWDL

  @Test func wifiLanCarriesOverAwdlEvenWhenAwdlSortsFirst() {
    let awdlClass = RelayLinkClass.classify(name: "awdl0", type: .wifi)
    let chosen = RelayLinkPolicy.chooseCarrying(
      preferred: nil,
      openLinks: [
        RelayLinkSnapshot(interfaceName: "awdl0", linkClass: awdlClass),
        RelayLinkSnapshot(interfaceName: "en0", linkClass: .wifiLan),
      ]
    )

    // With awdl0 correctly classed peer-to-peer, en0 outscores it, so the
    // alphabetical tie-break never makes awdl0 win.
    #expect(chosen == "en0")
  }
}

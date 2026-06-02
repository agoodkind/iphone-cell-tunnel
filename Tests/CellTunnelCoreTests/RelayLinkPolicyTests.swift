//
//  RelayLinkPolicyTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RelayLinkPolicyTests

struct RelayLinkPolicyTests {
    // MARK: - Default preference

    @Test func highestScoreCarriesByDefault() {
        let chosen = RelayLinkPolicy.chooseCarrying(
            preferred: nil,
            openLinks: [
                RelayLinkSnapshot(interfaceName: "awdl0", linkClass: .peerToPeer),
                RelayLinkSnapshot(interfaceName: "en2", linkClass: .wired),
                RelayLinkSnapshot(interfaceName: "en0", linkClass: .wifiLan),
            ]
        )

        // USB (wired) outranks Wi-Fi LAN outranks AWDL.
        #expect(chosen == "en2")
    }

    @Test func tiesBreakByInterfaceName() {
        let chosen = RelayLinkPolicy.chooseCarrying(
            preferred: nil,
            openLinks: [
                RelayLinkSnapshot(interfaceName: "en2", linkClass: .wired),
                RelayLinkSnapshot(interfaceName: "anpi0", linkClass: .wired),
            ]
        )

        // Two equal-rank wired links resolve to one deterministically, no flip.
        #expect(chosen == "anpi0")
    }

    // MARK: - Override (the switch primitive)

    @Test func overrideCarriesWhenOpen() {
        let chosen = RelayLinkPolicy.chooseCarrying(
            preferred: "awdl0",
            openLinks: [
                RelayLinkSnapshot(interfaceName: "en2", linkClass: .wired),
                RelayLinkSnapshot(interfaceName: "awdl0", linkClass: .peerToPeer),
            ]
        )

        #expect(chosen == "awdl0")
    }

    @Test func overrideIgnoredWhenNotOpen() {
        let chosen = RelayLinkPolicy.chooseCarrying(
            preferred: "awdl0",
            openLinks: [
                RelayLinkSnapshot(interfaceName: "en2", linkClass: .wired)
            ]
        )

        // The forced link is not open, so the default preference decides.
        #expect(chosen == "en2")
    }

    // MARK: - Empty

    @Test func noOpenLinkCarriesNothing() {
        #expect(RelayLinkPolicy.chooseCarrying(preferred: nil, openLinks: []) == nil)
        #expect(RelayLinkPolicy.chooseCarrying(preferred: "en2", openLinks: []) == nil)
    }
}

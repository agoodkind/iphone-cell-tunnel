//
//  RelayLinkPolicyTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RelayLinkPolicyTests

struct RelayLinkPolicyTests {
    // MARK: - Keep-warm coverage

    @Test func keepWarmIncludesEveryLinkOrderedByScore() {
        let plan = RelayLinkPolicy.plan(for: [
            RelayLinkSnapshot(interfaceName: "awdl0", linkClass: .peerToPeer, isLive: true),
            RelayLinkSnapshot(interfaceName: "en11", linkClass: .wired, isLive: true),
            RelayLinkSnapshot(interfaceName: "en0", linkClass: .wifiLan, isLive: true),
        ])

        #expect(plan.keepWarm == ["en11", "en0", "awdl0"])
    }

    // MARK: - Egress selection

    @Test func egressIsHighestScoringLiveLink() {
        let plan = RelayLinkPolicy.plan(for: [
            RelayLinkSnapshot(interfaceName: "en11", linkClass: .wired, isLive: false),
            RelayLinkSnapshot(interfaceName: "en0", linkClass: .wifiLan, isLive: true),
            RelayLinkSnapshot(interfaceName: "awdl0", linkClass: .peerToPeer, isLive: true),
        ])

        // Wired outscores Wi-Fi LAN but is dead, so egress falls to live Wi-Fi LAN.
        #expect(plan.egressInterfaceName == "en0")
        #expect(plan.egressOrder == ["en0", "awdl0"])
        #expect(plan.keepWarm == ["en11", "en0", "awdl0"])
    }

    @Test func noLiveLinkLeavesEgressEmpty() {
        let plan = RelayLinkPolicy.plan(for: [
            RelayLinkSnapshot(interfaceName: "en11", linkClass: .wired, isLive: false)
        ])

        #expect(plan.egressInterfaceName == nil)
        #expect(plan.egressOrder.isEmpty)
        #expect(plan.keepWarm == ["en11"])
    }

    @Test func emptyLinkSetYieldsEmptyPlan() {
        let plan = RelayLinkPolicy.plan(for: [])

        #expect(plan.keepWarm.isEmpty)
        #expect(plan.egressOrder.isEmpty)
    }

    @Test func tiesBreakByInterfaceName() {
        let plan = RelayLinkPolicy.plan(for: [
            RelayLinkSnapshot(interfaceName: "en5", linkClass: .wired, isLive: true),
            RelayLinkSnapshot(interfaceName: "en2", linkClass: .wired, isLive: true),
        ])

        #expect(plan.egressOrder == ["en2", "en5"])
    }
}

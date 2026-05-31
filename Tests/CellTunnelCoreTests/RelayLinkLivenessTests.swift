//
//  RelayLinkLivenessTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RelayLinkLivenessTests

struct RelayLinkLivenessTests {
    // MARK: - Deadlines

    @Test func peerToPeerDeadlineIsLooserThanLowLatency() {
        let peer = RelayLinkLiveness.deadlineMilliseconds(for: .peerToPeer)
        let wired = RelayLinkLiveness.deadlineMilliseconds(for: .wired)
        let wifi = RelayLinkLiveness.deadlineMilliseconds(for: .wifiLan)

        #expect(peer > wired)
        #expect(wired == wifi)
    }

    // MARK: - Alive window

    @Test func linkIsAliveWithinItsDeadline() {
        let deadline = RelayLinkLiveness.deadlineMilliseconds(for: .wired)
        let link = RelayLinkLiveness(linkClass: .wired, lastHeardMilliseconds: 1_000)

        #expect(link.isAlive(atMilliseconds: 1_000))
        #expect(link.isAlive(atMilliseconds: 1_000 + deadline))
    }

    @Test func linkIsDeadPastItsDeadline() {
        let deadline = RelayLinkLiveness.deadlineMilliseconds(for: .wired)
        let link = RelayLinkLiveness(linkClass: .wired, lastHeardMilliseconds: 1_000)

        #expect(!link.isAlive(atMilliseconds: 1_000 + deadline + 1))
    }

    @Test func peerToPeerSurvivesPastTheLowLatencyDeadline() {
        let lowLatency = RelayLinkLiveness.deadlineMilliseconds(for: .wired)
        let peer = RelayLinkLiveness(linkClass: .peerToPeer, lastHeardMilliseconds: 0)
        let wired = RelayLinkLiveness(linkClass: .wired, lastHeardMilliseconds: 0)

        // A delay that kills a wired link still leaves AWDL alive.
        #expect(!wired.isAlive(atMilliseconds: lowLatency + 1))
        #expect(peer.isAlive(atMilliseconds: lowLatency + 1))
    }
}

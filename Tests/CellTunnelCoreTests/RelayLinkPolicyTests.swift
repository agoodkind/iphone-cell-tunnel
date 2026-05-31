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
    // MARK: - Keep-open coverage

    @Test func activeBackupKeepsEveryLinkOrderedByPreference() {
        let plan = RelayLinkPolicy.plan(
            for: [
                RelayLinkSnapshot(
                    interfaceName: "awdl0", linkClass: .peerToPeer, silenceMilliseconds: 0
                ),
                RelayLinkSnapshot(
                    interfaceName: "en11", linkClass: .wired, silenceMilliseconds: 0
                ),
                RelayLinkSnapshot(
                    interfaceName: "en0", linkClass: .wifiLan, silenceMilliseconds: 0
                ),
            ],
            kind: .activeBackup
        )

        #expect(plan.keepWarm == ["en11", "en0", "awdl0"])
    }

    @Test func batterySaverKeepsOnlyTheTopLink() {
        let plan = RelayLinkPolicy.plan(
            for: [
                RelayLinkSnapshot(
                    interfaceName: "awdl0", linkClass: .peerToPeer, silenceMilliseconds: 0
                ),
                RelayLinkSnapshot(
                    interfaceName: "en11", linkClass: .wired, silenceMilliseconds: 0
                ),
            ],
            kind: .batterySaver
        )

        #expect(plan.keepWarm == ["en11"])
    }

    // MARK: - Carrying: fresh links and preference

    @Test func freshLinksCarryByPreference() {
        let plan = RelayLinkPolicy.plan(
            for: [
                RelayLinkSnapshot(
                    interfaceName: "awdl0", linkClass: .peerToPeer, silenceMilliseconds: 0
                ),
                RelayLinkSnapshot(
                    interfaceName: "en11", linkClass: .wired, silenceMilliseconds: 0
                ),
            ],
            kind: .activeBackup
        )

        #expect(plan.egressInterfaceName == "en11")
    }

    @Test func staleTopPreferenceYieldsToAFreshLowerLink() {
        // The cable outranks AWDL but has not delivered for 5 seconds, far past the
        // flap margin, while AWDL is fresh. The fresh link carries.
        let plan = RelayLinkPolicy.plan(
            for: [
                RelayLinkSnapshot(
                    interfaceName: "en11", linkClass: .wired, silenceMilliseconds: 5_000
                ),
                RelayLinkSnapshot(
                    interfaceName: "awdl0", linkClass: .peerToPeer, silenceMilliseconds: 50
                ),
            ],
            kind: .activeBackup
        )

        #expect(plan.egressInterfaceName == "awdl0")
        #expect(plan.egressOrder == ["awdl0", "en11"])
    }

    // MARK: - Carrying: blackout and all-slow fall back to preference

    @Test func blackoutKeepsPreferenceAndNeverEmpties() {
        // Every link is silent for about ten seconds. Their silences are close, so
        // all keep up relative to each other and the preference decides; the
        // carrying link never vanishes.
        let plan = RelayLinkPolicy.plan(
            for: [
                RelayLinkSnapshot(
                    interfaceName: "awdl0", linkClass: .peerToPeer, silenceMilliseconds: 10_500
                ),
                RelayLinkSnapshot(
                    interfaceName: "en11", linkClass: .wired, silenceMilliseconds: 10_000
                ),
            ],
            kind: .activeBackup
        )

        #expect(plan.egressInterfaceName == "en11")
        #expect(plan.egressOrder == ["en11", "awdl0"])
    }

    @Test func allSlowComparesRelativelyAndKeepsPreference() {
        // Both paths are slow at about two seconds. They are close, so both keep up
        // and the cable carries.
        let plan = RelayLinkPolicy.plan(
            for: [
                RelayLinkSnapshot(
                    interfaceName: "en0", linkClass: .wifiLan, silenceMilliseconds: 2_100
                ),
                RelayLinkSnapshot(
                    interfaceName: "en11", linkClass: .wired, silenceMilliseconds: 2_000
                ),
            ],
            kind: .activeBackup
        )

        #expect(plan.egressInterfaceName == "en11")
    }

    @Test func oneLinkAlwaysCarries() {
        let plan = RelayLinkPolicy.plan(
            for: [
                RelayLinkSnapshot(
                    interfaceName: "en11", linkClass: .wired, silenceMilliseconds: 99_000
                )
            ],
            kind: .activeBackup
        )

        #expect(plan.egressInterfaceName == "en11")
    }

    @Test func emptyLinkSetYieldsEmptyPlan() {
        let plan = RelayLinkPolicy.plan(for: [], kind: .activeBackup)

        #expect(plan.keepWarm.isEmpty)
        #expect(plan.egressInterfaceName == nil)
    }
}

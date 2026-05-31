//
//  RelayPathEvaluationTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RelayPathEvaluationTests

struct RelayPathEvaluationTests {
    // MARK: - Class ranking

    @Test func wiredOutranksWifiLanOutranksPeerToPeer() {
        let wired = RelayLinkScorer.score(
            linkClass: .wired, isExpensive: false, isConstrained: false
        )
        let wifiLan = RelayLinkScorer.score(
            linkClass: .wifiLan, isExpensive: false, isConstrained: false
        )
        let peerToPeer = RelayLinkScorer.score(
            linkClass: .peerToPeer, isExpensive: false, isConstrained: false
        )

        #expect(wired > wifiLan)
        #expect(wifiLan > peerToPeer)
    }

    // MARK: - Flag penalties

    @Test func expensiveAndConstrainedLowerTheScore() {
        let plain = RelayLinkScorer.score(
            linkClass: .wired, isExpensive: false, isConstrained: false
        )
        let expensive = RelayLinkScorer.score(
            linkClass: .wired, isExpensive: true, isConstrained: false
        )
        let constrained = RelayLinkScorer.score(
            linkClass: .wired, isExpensive: false, isConstrained: true
        )
        let both = RelayLinkScorer.score(
            linkClass: .wired, isExpensive: true, isConstrained: true
        )

        #expect(expensive < plain)
        #expect(constrained < plain)
        #expect(both < expensive)
        #expect(both < constrained)
    }

    // MARK: - Link capability filter

    @Test func onlyWiredWifiAndPeerToPeerCarryTheLink() {
        #expect(RelayLinkClass.wired.isMacLinkCapable)
        #expect(RelayLinkClass.wifiLan.isMacLinkCapable)
        #expect(RelayLinkClass.peerToPeer.isMacLinkCapable)
        #expect(!RelayLinkClass.cellular.isMacLinkCapable)
        #expect(!RelayLinkClass.loopback.isMacLinkCapable)
        #expect(!RelayLinkClass.other.isMacLinkCapable)
    }

    // MARK: - Evaluation ordering

    @Test func evaluationSortsBestFirst() {
        let evaluation = RelayPathEvaluation(candidates: [
            RelayLinkCandidate(
                interfaceName: "awdl0",
                linkClass: .peerToPeer,
                isExpensive: false,
                isConstrained: false
            ),
            RelayLinkCandidate(
                interfaceName: "en11",
                linkClass: .wired,
                isExpensive: false,
                isConstrained: false
            ),
            RelayLinkCandidate(
                interfaceName: "en0",
                linkClass: .wifiLan,
                isExpensive: false,
                isConstrained: false
            ),
        ])

        #expect(evaluation.best?.interfaceName == "en11")
        #expect(evaluation.candidates.map(\.interfaceName) == ["en11", "en0", "awdl0"])
    }

    @Test func evaluationWithNoCandidatesHasNoBest() {
        let evaluation = RelayPathEvaluation(candidates: [])

        #expect(evaluation.best == nil)
    }

    @Test func equalScoresBreakTiesByInterfaceName() {
        let evaluation = RelayPathEvaluation(candidates: [
            RelayLinkCandidate(
                interfaceName: "en5",
                linkClass: .wired,
                isExpensive: false,
                isConstrained: false
            ),
            RelayLinkCandidate(
                interfaceName: "en2",
                linkClass: .wired,
                isExpensive: false,
                isConstrained: false
            ),
        ])

        #expect(evaluation.candidates.map(\.interfaceName) == ["en2", "en5"])
    }
}

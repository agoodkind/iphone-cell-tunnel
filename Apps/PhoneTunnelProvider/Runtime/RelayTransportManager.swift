//
//  RelayTransportManager.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - RelayDialStrategy

/// How the forwarder should dial the Mac for a candidate link. Infrastructure
/// dials with peer-to-peer off, so the connection uses the wired USB link or
/// Wi-Fi LAN. Peer-to-peer dials with it on, so the system may bring up AWDL when
/// no faster path exists.
enum RelayDialStrategy: String, Sendable {
    case infrastructure
    case peerToPeer
}

// MARK: - RelayDesiredTransport

/// The transport the manager wants right now: which link class, what it scored,
/// and how the forwarder should dial it. Computed from the latest evaluation.
struct RelayDesiredTransport: Sendable {
    let linkClass: RelayLinkClass
    let score: Int
    let strategy: RelayDialStrategy
}

// MARK: - RelayTransportManager

/// The deciding half of path selection. It receives a scored evaluation from the
/// probe on every interface change, compares the best candidate to the link the
/// relay is on, and switches only when the best beats the active link by a
/// margin. A switch is make-before-break: it asks the forwarder to dial the new
/// path, and only after that path is ready does it promote it and drop the old
/// one, so traffic is never stopped to probe or to switch. A dropped link and a
/// replugged cable are ordinary evaluation triggers, so redial and return-to-wired
/// both come from this one path.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. The probe callback and the forwarder callbacks hop onto
/// `queue` before touching state.
final class RelayTransportManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CellTunnelPhone.RelayTransportManager")
    private weak var link: PhoneRelayForwarder?

    private var activeClass: RelayLinkClass?
    private var activeScore = 0
    private var pendingStrategy: RelayDialStrategy?
    private var pendingClass: RelayLinkClass?
    private var pendingScore = 0
    private var latestEvaluation: RelayPathEvaluation?
    private var debounceTimer: DispatchSourceTimer?

    init(link: PhoneRelayForwarder) {
        self.link = link
    }

    // MARK: - Probe input

    /// Receives an evaluation from the probe. Coalesces a burst of interface
    /// changes into one decision so an interface that bounces does not churn the
    /// link.
    func handle(evaluation: RelayPathEvaluation) {
        queue.async { [weak self] in
            self?.scheduleDecision(with: evaluation)
        }
    }

    private func scheduleDecision(with evaluation: RelayPathEvaluation) {
        logger.debug(
            "relay transport evaluation received count=\(evaluation.candidates.count, privacy: .public)"
        )
        latestEvaluation = evaluation
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(RelayTransportPolicy.evaluationDebounceMilliseconds)
        )
        timer.setEventHandler { @Sendable [weak self] in
            self?.decide()
        }
        timer.resume()
        debounceTimer = timer
    }

    // MARK: - Decision

    private func decide() {
        guard let evaluation = latestEvaluation else {
            return
        }
        let desired = desiredTransport(for: evaluation)
        let activeClassName = activeClass?.rawValue ?? "none"
        logger.notice(
            """
            relay transport deciding desiredClass=\(desired.linkClass.rawValue, privacy: .public) \
            desiredScore=\(desired.score, privacy: .public) \
            activeClass=\(activeClassName, privacy: .public)
            """
        )

        if activeClass == nil {
            startEstablish(desired)
            return
        }
        if let pendingStrategy {
            preemptIfBetter(desired, pendingStrategy: pendingStrategy)
            return
        }
        if desired.linkClass == activeClass {
            activeScore = desired.score
            return
        }
        if desired.score > activeScore + RelayTransportPolicy.switchScoreMargin {
            startEstablish(desired)
        }
    }

    private func desiredTransport(for evaluation: RelayPathEvaluation) -> RelayDesiredTransport {
        guard let best = evaluation.best else {
            let peerScore = RelayLinkScorer.score(
                linkClass: .peerToPeer, isExpensive: false, isConstrained: false
            )
            return RelayDesiredTransport(
                linkClass: .peerToPeer, score: peerScore, strategy: .peerToPeer
            )
        }
        return RelayDesiredTransport(
            linkClass: best.linkClass,
            score: best.score,
            strategy: dialStrategy(for: best.linkClass)
        )
    }

    private func dialStrategy(for linkClass: RelayLinkClass) -> RelayDialStrategy {
        switch linkClass {
        case .peerToPeer:
            .peerToPeer
        default:
            .infrastructure
        }
    }

    private func preemptIfBetter(
        _ desired: RelayDesiredTransport, pendingStrategy: RelayDialStrategy
    ) {
        guard desired.strategy != pendingStrategy,
            desired.score > pendingScore + RelayTransportPolicy.switchScoreMargin
        else {
            return
        }
        logger.notice(
            """
            relay transport preempting pending dial \
            from=\(pendingStrategy.rawValue, privacy: .public) \
            to=\(desired.strategy.rawValue, privacy: .public)
            """
        )
        link?.cancelPendingEstablish()
        clearPending()
        startEstablish(desired)
    }

    private func startEstablish(_ desired: RelayDesiredTransport) {
        pendingStrategy = desired.strategy
        pendingClass = desired.linkClass
        pendingScore = desired.score
        logger.notice(
            """
            relay transport establishing candidate \
            class=\(desired.linkClass.rawValue, privacy: .public) \
            strategy=\(desired.strategy.rawValue, privacy: .public) \
            score=\(desired.score, privacy: .public)
            """
        )
        link?.establishCandidate(strategy: desired.strategy)
    }

    private func clearPending() {
        pendingStrategy = nil
        pendingClass = nil
        pendingScore = 0
    }

    // MARK: - Forwarder callbacks

    /// The forwarder reports the candidate it was asked to dial is ready. If it is
    /// still the wanted candidate, promote it (break the old link) and record it
    /// as active.
    func candidateDidBecomeReady(strategy: RelayDialStrategy) {
        queue.async { [weak self] in
            guard let self, pendingStrategy == strategy else {
                return
            }
            link?.promotePendingToActive()
            activeClass = pendingClass
            activeScore = pendingScore
            let activeClassName = pendingClass?.rawValue ?? "none"
            let switchedScore = pendingScore
            logger.notice(
                """
                relay transport switched active link \
                class=\(activeClassName, privacy: .public) \
                score=\(switchedScore, privacy: .public)
                """
            )
            clearPending()
        }
    }

    /// The forwarder reports the candidate dial failed or timed out. Fall back
    /// from infrastructure to peer-to-peer; if peer-to-peer also failed, wait for
    /// the next evaluation to try again.
    func candidateDidFail(strategy: RelayDialStrategy) {
        queue.async { [weak self] in
            guard let self, pendingStrategy == strategy else {
                return
            }
            clearPending()
            logger.notice(
                "relay transport candidate failed strategy=\(strategy.rawValue, privacy: .public)"
            )
            if strategy == .infrastructure {
                let peerScore = RelayLinkScorer.score(
                    linkClass: .peerToPeer, isExpensive: false, isConstrained: false
                )
                startEstablish(
                    RelayDesiredTransport(
                        linkClass: .peerToPeer, score: peerScore, strategy: .peerToPeer
                    )
                )
            }
        }
    }

    /// The forwarder reports the active link dropped. Clear it and re-decide from
    /// the latest evaluation so the relay re-establishes on the best path now.
    func activeLinkDidDrop() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            activeClass = nil
            activeScore = 0
            logger.notice("relay transport active link dropped, re-establishing")
            if pendingStrategy == nil {
                decide()
            }
        }
    }

    // MARK: - Lifecycle

    func stop() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            debounceTimer?.cancel()
            debounceTimer = nil
            activeClass = nil
            activeScore = 0
            clearPending()
            latestEvaluation = nil
            logger.notice("relay transport manager stopped")
        }
    }
}

//
//  PhoneRelayForwarder+Link.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let relayServiceType = "_cellrelay._udp"

// MARK: - Mac-facing link, make-before-break

/// The transport manager drives this surface to switch the Mac-facing link
/// without stopping traffic. `establishCandidate` dials a candidate to the agent
/// over the chosen path class but does not prime or read it, so the agent does
/// not adopt it and the old link keeps carrying. `promotePendingToActive` swaps
/// the ready candidate in, primes it so the agent adopts it, and drops the old
/// one. Every method runs only on `PhoneRelayForwarder.queue`.
extension PhoneRelayForwarder {
    // MARK: - Manager entry points (hop onto the relay queue)

    func establishCandidate(strategy: RelayDialStrategy) {
        queue.async { [weak self] in
            self?.establishOnQueue(strategy: strategy)
        }
    }

    func promotePendingToActive() {
        queue.async { [weak self] in
            self?.promoteOnQueue()
        }
    }

    func cancelPendingEstablish() {
        queue.async { [weak self] in
            self?.cancelPendingEstablishOnQueue()
        }
    }

    // MARK: - Candidate establishment (the make half)

    private func establishOnQueue(strategy: RelayDialStrategy) {
        cancelPendingEstablishOnQueue()
        pendingStrategy = strategy
        let parameters = NWParameters()
        parameters.includePeerToPeer = strategy == .peerToPeer
        let descriptor = NWBrowser.Descriptor.bonjour(type: relayServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state, strategy: strategy)
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results, strategy: strategy)
        }
        browser.start(queue: queue)
        pendingBrowser = browser
        logger.notice(
            """
            phone relay establishing candidate strategy=\(strategy.rawValue, privacy: .public) \
            service=\(relayServiceType, privacy: .public)
            """
        )
    }

    private func handleBrowserState(_ state: NWBrowser.State, strategy: RelayDialStrategy) {
        switch state {
        case .ready:
            logger.notice(
                "phone relay candidate browser ready strategy=\(strategy.rawValue, privacy: .public)"
            )
        case .failed(let error):
            logger.error(
                """
                phone relay candidate browser failed \
                strategy=\(strategy.rawValue, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
            failPending(strategy: strategy)
        default:
            break
        }
    }

    private func handleBrowseResults(
        _ results: Set<NWBrowser.Result>, strategy: RelayDialStrategy
    ) {
        guard pendingStrategy == strategy, pendingConnection == nil else {
            return
        }
        for result in results {
            if case .service = result.endpoint {
                dialPendingOnQueue(endpoint: result.endpoint, strategy: strategy)
                return
            }
        }
    }

    private func dialPendingOnQueue(endpoint: NWEndpoint, strategy: RelayDialStrategy) {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = strategy == .peerToPeer
        let connection = NWConnection(to: endpoint, using: parameters)
        pendingConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else {
                return
            }
            self?.handlePendingState(state, connection: connection, strategy: strategy)
        }
        connection.start(queue: queue)
        startEstablishTimer(strategy: strategy)
        logger.notice(
            """
            phone relay dialing candidate strategy=\(strategy.rawValue, privacy: .public) \
            endpoint=\(String(describing: connection.endpoint), privacy: .public)
            """
        )
    }

    private func handlePendingState(
        _ state: NWConnection.State, connection: NWConnection, strategy: RelayDialStrategy
    ) {
        guard pendingConnection === connection else {
            return
        }
        switch state {
        case .ready:
            establishTimer?.cancel()
            establishTimer = nil
            pendingBrowser?.cancel()
            pendingBrowser = nil
            logger.notice(
                "phone relay candidate ready strategy=\(strategy.rawValue, privacy: .public)"
            )
            onCandidateReady?(strategy)
        case .failed(let error):
            logger.error(
                """
                phone relay candidate failed strategy=\(strategy.rawValue, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
            failPending(strategy: strategy)
        default:
            break
        }
    }

    private func startEstablishTimer(strategy: RelayDialStrategy) {
        establishTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .seconds(RelayTransportPolicy.candidateEstablishTimeoutSeconds)
        )
        timer.setEventHandler { @Sendable [weak self] in
            guard let self else {
                return
            }
            logger.error(
                "phone relay candidate timed out strategy=\(strategy.rawValue, privacy: .public)"
            )
            failPending(strategy: strategy)
        }
        timer.resume()
        establishTimer = timer
    }

    private func failPending(strategy: RelayDialStrategy) {
        cancelPendingEstablishOnQueue()
        onCandidateFailed?(strategy)
    }

    func cancelPendingEstablishOnQueue() {
        let hadPending = pendingBrowser != nil || pendingConnection != nil
        establishTimer?.cancel()
        establishTimer = nil
        pendingBrowser?.cancel()
        pendingBrowser = nil
        pendingConnection?.cancel()
        pendingConnection = nil
        pendingStrategy = nil
        if hadPending {
            logger.notice("phone relay candidate establishment cancelled")
        }
    }

    // MARK: - Promotion (the break half)

    private func promoteOnQueue() {
        guard let promoted = pendingConnection else {
            logger.error("phone relay promote requested with no pending candidate")
            return
        }
        establishTimer?.cancel()
        establishTimer = nil
        pendingBrowser?.cancel()
        pendingBrowser = nil
        pendingConnection = nil
        pendingStrategy = nil

        let previous = macConnection
        macConnection = promoted
        promoted.stateUpdateHandler = { [weak self, weak promoted] state in
            guard let promoted else {
                return
            }
            self?.handleMacConnectionState(state, connection: promoted)
        }
        previous?.cancel()
        onPeerChange?("Mac")
        logger.notice("phone relay promoted candidate to active link")
        receiveFromMac(on: promoted)
        primeMacConnection(promoted)
    }

    // A UDP NWConnection has no peer until the first datagram is sent, so the
    // agent cannot learn the iPhone source endpoint to route replies. Send one
    // empty datagram on promotion so the agent adopts this connection as the
    // phone side. Priming only on promotion is what keeps make-before-break safe:
    // an un-primed candidate is invisible to the agent, so the old link keeps
    // carrying until the new one takes over here.
    private func primeMacConnection(_ connection: NWConnection) {
        connection.send(
            content: Data(),
            completion: .contentProcessed { error in
                guard let error else {
                    return
                }
                logger.error(
                    "phone relay mac prime failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        )
    }
}

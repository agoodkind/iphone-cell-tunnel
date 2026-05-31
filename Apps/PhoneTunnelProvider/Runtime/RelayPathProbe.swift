//
//  RelayPathProbe.swift
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
private let infrastructureCandidateName = "infrastructure"

// MARK: - RelayPathProbe

/// Senses whether a fast wired or Wi-Fi LAN path to the Mac is available and
/// reports it as a scored evaluation. It is the generic sensing half of path
/// selection: it only looks and reports, never dials the data plane, so it cannot
/// stop traffic in flight. The transport manager consumes each evaluation and
/// decides whether to switch.
///
/// Inside a packet-tunnel extension `NWPathMonitor` only sees the extension's own
/// scoped paths, the cellular egress and the tunnel, and never the local link to
/// the Mac. A Bonjour browse is the one mechanism that surfaces the Mac link from
/// here. So the probe browses the relay service with peer-to-peer off: a result
/// means the agent is reachable over the wired USB link or Wi-Fi LAN, the fast
/// paths. No result means only the Apple peer-to-peer link (AWDL) is left, which
/// the manager reads as the cue to dial with peer-to-peer allowed. The browse
/// carries no data, so the probe never disturbs the live connection.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`, and the browser starts with `.start(queue: queue)`.
final class RelayPathProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CellTunnelPhone.RelayPathProbe")
    private var browser: NWBrowser?
    private var hasInfrastructure = false

    /// Called when wired or Wi-Fi LAN availability to the Mac changes, with the
    /// freshly scored evaluation. Set before `start()`. Fires on the probe queue;
    /// the manager hops as needed.
    var onEvaluation: (@Sendable (RelayPathEvaluation) -> Void)?

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.startBrowseOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
            logger.notice("relay path probe stopped")
        }
    }

    // MARK: - Infrastructure browse

    private func startBrowseOnQueue() {
        let parameters = NWParameters()
        // Peer-to-peer off so the browse only discovers the agent over the wired
        // USB link and Wi-Fi LAN, never AWDL. Presence of a result is the wired
        // availability signal.
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: relayServiceType, domain: nil)
        let nwBrowser = NWBrowser(for: descriptor, using: parameters)
        nwBrowser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state)
        }
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        nwBrowser.start(queue: queue)
        browser = nwBrowser
        logger.notice(
            "relay path probe browsing infrastructure service=\(relayServiceType, privacy: .public)"
        )
        emitEvaluation()
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            logger.notice("relay path probe infrastructure browser ready")
        case .failed(let error):
            logger.error(
                "relay path probe browser failed error=\(error.localizedDescription, privacy: .public)"
            )
            setInfrastructure(present: false)
        default:
            break
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        let present = results.contains { result in
            if case .service = result.endpoint {
                return true
            }
            return false
        }
        setInfrastructure(present: present)
    }

    // MARK: - Evaluation

    /// Emits only when availability changes, so a steady state does not churn the
    /// manager. The manager re-decides on its own when a link drops.
    private func setInfrastructure(present: Bool) {
        guard present != hasInfrastructure else {
            return
        }
        hasInfrastructure = present
        logger.notice(
            "relay path probe infrastructure availability changed present=\(present, privacy: .public)"
        )
        emitEvaluation()
    }

    private func emitEvaluation() {
        let candidates: [RelayLinkCandidate]
        if hasInfrastructure {
            let candidate = RelayLinkCandidate(
                interfaceName: infrastructureCandidateName,
                linkClass: .wired,
                isExpensive: false,
                isConstrained: false
            )
            candidates = [candidate]
        } else {
            candidates = []
        }
        onEvaluation?(RelayPathEvaluation(candidates: candidates))
    }
}

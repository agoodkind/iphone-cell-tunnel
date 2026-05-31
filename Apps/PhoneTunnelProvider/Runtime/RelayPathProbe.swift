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
private let awdlInterfaceNamePrefix = "awdl"

// MARK: - RelayPathProbe

/// Watches the iPhone network interfaces and, on every change, produces a scored
/// evaluation of the links that could carry the relay to the Mac. It is the
/// generic sensing half of path selection: it only looks and reports, and never
/// dials or touches the live connection, so it cannot stop traffic in flight.
/// The transport manager consumes each evaluation and decides whether to switch.
///
/// The probe surfaces the infrastructure links it can see (wired USB and Wi-Fi
/// LAN). The Apple peer-to-peer link (AWDL) does not appear in the interface
/// list until a peer-to-peer connection already exists, so the probe does not
/// invent it; the manager reads an empty or non-peer evaluation as the cue to
/// dial with peer-to-peer allowed and let the system bring AWDL up on demand.
///
/// The `@unchecked Sendable` contract: the monitor runs on `monitorQueue` and the
/// only stored handler is read there, so there is no shared mutable state.
final class RelayPathProbe: @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "CellTunnelPhone.RelayPathProbe")
    private let monitor = NWPathMonitor()

    /// Called on every interface change with the freshly scored evaluation. Set
    /// before `start()`. Fires on the probe queue; the manager hops as needed.
    var onEvaluation: (@Sendable (RelayPathEvaluation) -> Void)?

    // MARK: - Lifecycle

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path: path)
        }
        monitor.start(queue: monitorQueue)
        logger.notice("relay path probe started")
    }

    func stop() {
        monitor.cancel()
        logger.notice("relay path probe stopped")
    }

    // MARK: - Evaluation

    private func handle(path: NWPath) {
        let candidates = path.availableInterfaces.compactMap { interface in
            candidate(for: interface, path: path)
        }
        let evaluation = RelayPathEvaluation(candidates: candidates)
        let summary = evaluation.candidates
            .map { "\($0.interfaceName):\($0.linkClass.rawValue):\($0.score)" }
            .joined(separator: ",")
        logger.notice(
            """
            relay path probe evaluation best=\(evaluation.best?.interfaceName ?? "none", privacy: .public) \
            bestClass=\(evaluation.best?.linkClass.rawValue ?? "none", privacy: .public) \
            candidates=\(summary, privacy: .public)
            """
        )
        onEvaluation?(evaluation)
    }

    private func candidate(for interface: NWInterface, path: NWPath) -> RelayLinkCandidate? {
        let linkClass = Self.linkClass(for: interface)
        guard linkClass.isMacLinkCapable else {
            return nil
        }
        return RelayLinkCandidate(
            interfaceName: interface.name,
            linkClass: linkClass,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    // MARK: - Interface classification

    /// Maps a network interface to a relay link class. AWDL rides the Wi-Fi radio
    /// and surfaces with a `wifi` or `other` type, so the `awdl` name prefix is
    /// the reliable signal that separates the peer-to-peer link from real Wi-Fi
    /// LAN. The mapping is total so every interface lands in one class.
    private static func linkClass(for interface: NWInterface) -> RelayLinkClass {
        if interface.name.hasPrefix(awdlInterfaceNamePrefix) {
            return .peerToPeer
        }
        switch interface.type {
        case .wiredEthernet:
            return .wired
        case .wifi:
            return .wifiLan
        case .cellular:
            return .cellular
        case .loopback:
            return .loopback
        case .other:
            return .other
        @unknown default:
            return .other
        }
    }
}

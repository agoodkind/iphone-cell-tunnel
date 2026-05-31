//
//  PhoneRelayForwarder.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - PhoneMacLink

/// One open link to the Mac agent, keyed by the iPhone interface it runs over.
/// The forwarder keeps one per reachable interface at once, so a loss of the
/// carrying link moves traffic to another already-open link. `isReady` gates a
/// link out of the carrying set until its connection is up and primed.
struct PhoneMacLink {
    let interfaceName: String
    let linkClass: RelayLinkClass
    let connection: NWConnection
    var isReady: Bool
}

// MARK: - PhoneRelayForwarder

/// Owns the entire iPhone relay data plane on one serial queue: the set of warm
/// Mac-facing links keyed by interface, the cellular NWConnection to the
/// WireGuard server, the connecting/ready state machine with its pending buffer,
/// and the lock-free `RelayMetrics`. Every datagram in both directions is
/// received, wrapped, and forwarded on this one queue with no per-packet actor
/// hop, so throughput is not gated by the MainActor.
///
/// Multi-link: the probe reports which interfaces the agent is reachable on, the
/// forwarder dials one link per interface and keeps them all open, and the chooser
/// picks the carrying link the download path sends on (the override if set, else
/// the highest-scoring open link). A link closes only when its connection errors;
/// the carrying link is recomputed on each open or close, never on a timer. The
/// dial, prime, and carrying choice live in `PhoneRelayForwarder+Link.swift`; the
/// cellular and download halves live in `PhoneRelayForwarder+Cellular.swift`.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects and timers start with `queue`, so their
/// callbacks fire on `queue`, and the public API funnels through `queue.async`.
/// Lifecycle transitions are pushed to the MainActor UI through the `@Sendable`
/// callbacks; nothing on the per-packet path touches MainActor.
final class PhoneRelayForwarder: @unchecked Sendable {
    let metrics = RelayMetrics()

    let queue = DispatchQueue(label: "CellTunnelPhone.RelayPlane")

    // The open Mac-facing links keyed by iPhone interface name and the cached
    // carrying pointer the download path reads per datagram. `egressInterfaceName`
    // records which link is carrying so the chooser can keep it stable.
    // `preferredInterface` is the override a UI or a future algorithm sets to force
    // the carrying link; nil means use the score order. All touched only on `queue`.
    var macLinks: [String: PhoneMacLink] = [:]
    var egressConnection: NWConnection?
    var egressInterfaceName: String?
    var preferredInterface: String?
    var hasLivePeer = false

    var cellularConnection: NWConnection?
    var endpointFamily = RelayAddressFamily.ipv4
    var state = WireGuardDatagramRelayState.stopped
    var pendingDatagrams: [WireGuardDatagram] = []
    var configuredEndpoint: RelayEndpoint?

    // Bounds the datagrams handed to the cellular socket but not yet accepted, so
    // an upload faster than the cellular uplink cannot balloon the OS send buffer.
    // The window sizes the bound from the measured send-buffer wait to hold loaded
    // upload latency low; the counter is the datagrams currently in flight against
    // it. Both are read and written only on `queue`, so neither needs an atomic.
    var cellularSendWindow = CellularSendWindow()
    var outstandingCellularSends = 0
    var loggedSendAllowance = 0

    // Once-only flags so each boundary function logs context exactly once
    // (satisfying the boundary-log audit) instead of logging per datagram.
    let didLogMacReceive = Atomic<Bool>(false)
    let didLogMacSend = Atomic<Bool>(false)
    let didLogCellularReceive = Atomic<Bool>(false)
    let didLogCellularSend = Atomic<Bool>(false)

    var onStateChange: (@Sendable (WireGuardDatagramRelayState) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onPeerChange: (@Sendable (String?) -> Void)?

    // MARK: - Public API (MainActor callers funnel onto the relay queue)

    func start() {
        logger.notice("phone relay forwarder ready, awaiting discovery")
    }

    /// Forces the carrying link to a specific interface, or returns to the score
    /// order when `interfaceName` is nil. This is the switch primitive a UI or a
    /// future selection algorithm calls; it recomputes the carrying link at once.
    func setPreferredInterface(_ interfaceName: String?) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            preferredInterface = interfaceName
            logger.notice(
                "phone relay preferred interface set to \(interfaceName ?? "auto", privacy: .public)"
            )
            recomputeEgress()
        }
    }

    func setServerEndpoint(_ endpoint: RelayEndpoint) {
        logger.notice(
            """
            phone relay forwarder server endpoint host=\(endpoint.host, privacy: .public) \
            port=\(endpoint.port, privacy: .public)
            """
        )
        queue.async { [weak self] in
            self?.applyEndpointOnQueue(endpoint)
        }
    }

    /// Receives the current set of reachable Mac interfaces from the probe and
    /// keeps the link set in step: dial any new interface, drop any that vanished.
    func reconcileLinks(_ interfaces: [RelayMacInterface]) {
        queue.async { [weak self] in
            self?.reconcileOnQueue(interfaces)
        }
    }

    /// Drops every link so they re-establish from the next discovery. The provider
    /// calls this when the control plane reports the agent died or restarted,
    /// because a UDP data link does not surface that drop on its own.
    func resetLinks() {
        queue.async { [weak self] in
            self?.resetLinksOnQueue()
        }
    }

    func stop() {
        logger.notice("phone relay forwarder stop requested")
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    // MARK: - Upload hot path (Mac -> server), queue-only, no actor hop

    /// Receives upload datagrams on one Mac link. Every link runs its own loop, so
    /// the iPhone forwards the Mac's upload no matter which link the agent egresses
    /// on. An empty datagram is a heartbeat: it refreshes the link's liveness and
    /// is not forwarded to the server (it is only the agent's adoption prime).
    func receiveFromMac(on connection: NWConnection, interfaceName: String) {
        if didLogMacReceive.compareExchange(
            expected: false, desired: true, ordering: .relaxed
        ).exchanged {
            logger.notice("phone relay mac receive loop armed")
        }
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else {
                return
            }
            guard isCurrentLink(connection, interfaceName: interfaceName) else {
                return
            }
            if let error {
                handleLinkReceiveError(error, connection: connection, interfaceName: interfaceName)
                return
            }
            if let data, !data.isEmpty {
                metrics.addBytesIn(UInt64(data.count))
                metrics.addDatagramsFromMac()
                sendToServer(data)
            }
            receiveFromMac(on: connection, interfaceName: interfaceName)
        }
    }

    private func sendToServer(_ data: Data) {
        do {
            let datagram = try WireGuardDatagram(data: data, addressFamily: .ipv4)
            if state == .connecting {
                bufferPendingDatagram(datagram)
                return
            }
            guard state == .ready else {
                metrics.addDropped()
                logger.error(
                    "phone relay send rejected state=\(self.state.rawValue, privacy: .public)"
                )
                return
            }
            cellularSend(datagram)
        } catch {
            metrics.addDropped()
            logger.error(
                "phone relay datagram from mac rejected error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

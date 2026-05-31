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

/// One warm link to the Mac agent, keyed by the iPhone interface it runs over.
/// The forwarder keeps one per reachable interface at once, so an abrupt loss of
/// any link fails over to another without a redial. `lastHeardMilliseconds` is
/// refreshed on every datagram, empty heartbeat or real data, and feeds the
/// liveness check; `isReady` gates a link out of the egress set until its
/// connection is up and primed.
struct PhoneMacLink {
    let interfaceName: String
    let linkClass: RelayLinkClass
    let connection: NWConnection
    var lastHeardMilliseconds: Int
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
/// Multi-link active-backup: the probe reports which interfaces the agent is
/// reachable on, the forwarder dials one link per interface and keeps them all
/// warm with a heartbeat, and the shared policy selects the single highest-scoring
/// live link as the egress the download path sends on. An abrupt loss of the
/// egress link is caught by a connection error or a missed liveness deadline, and
/// the egress moves to the next live link with no redial. The dial, prime,
/// heartbeat, and liveness live in `PhoneRelayForwarder+Link.swift`; the cellular
/// and download halves live in `PhoneRelayForwarder+Cellular.swift`.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects and timers start with `queue`, so their
/// callbacks fire on `queue`, and the public API funnels through `queue.async`.
/// Lifecycle transitions are pushed to the MainActor UI through the `@Sendable`
/// callbacks; nothing on the per-packet path touches MainActor.
final class PhoneRelayForwarder: @unchecked Sendable {
    let metrics = RelayMetrics()

    let queue = DispatchQueue(label: "CellTunnelPhone.RelayPlane")

    // The warm Mac-facing links keyed by iPhone interface name, the cached egress
    // pointer the download path reads per datagram, and the maintenance timer that
    // sends heartbeats and reaps dead links. All touched only on `queue`.
    var macLinks: [String: PhoneMacLink] = [:]
    var egressConnection: NWConnection?
    var linkMaintenanceTimer: DispatchSourceTimer?
    var hasLivePeer = false

    var cellularConnection: NWConnection?
    var endpointFamily = RelayAddressFamily.ipv4
    var state = WireGuardDatagramRelayState.stopped
    var pendingDatagrams: [WireGuardDatagram] = []
    var configuredEndpoint: RelayEndpoint?

    // Bounds the datagrams handed to the cellular socket but not yet accepted, so
    // an upload faster than the cellular uplink cannot balloon the OS send buffer.
    // Without this cap the buffer grows under upload load, inflating latency and
    // throttling the upload; dropping past the cap lets WireGuard pace itself.
    let outstandingCellularSends = Atomic<Int>(0)

    // Once-only flags so each boundary function logs context exactly once
    // (satisfying the boundary-log audit) instead of logging per datagram.
    let didLogMacReceive = Atomic<Bool>(false)
    let didLogMacSend = Atomic<Bool>(false)
    let didLogMacHeartbeat = Atomic<Bool>(false)
    let didLogCellularReceive = Atomic<Bool>(false)
    let didLogCellularSend = Atomic<Bool>(false)

    var onStateChange: (@Sendable (WireGuardDatagramRelayState) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onPeerChange: (@Sendable (String?) -> Void)?

    // MARK: - Public API (MainActor callers funnel onto the relay queue)

    func start() {
        queue.async { [weak self] in
            self?.startMaintenanceTimer()
        }
        logger.notice("phone relay forwarder ready, awaiting discovery")
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
    /// is not forwarded to the server.
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
            stampLastHeard(interfaceName: interfaceName)
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

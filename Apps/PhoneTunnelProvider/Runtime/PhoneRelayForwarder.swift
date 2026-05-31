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

// MARK: - PhoneRelayForwarder

/// Owns the entire iPhone relay data plane on one serial queue: the Mac-facing
/// NWConnection dialed to the agent, the cellular NWConnection to the WireGuard
/// server, the connecting/ready state machine with its pending buffer, and the
/// lock-free `RelayMetrics`. Every datagram in both directions is received,
/// wrapped, and forwarded on this one queue with no per-packet actor hop, so
/// throughput is not gated by the MainActor. The queue serializes only code
/// execution for race-free shared state; the datagrams stay independent UDP
/// sends with no added ordering or reliability.
///
/// The transport manager chooses the Mac-facing link, not this class. The
/// make-before-break dial and swap live in `PhoneRelayForwarder+Link.swift`, and
/// the cellular and download halves live in `PhoneRelayForwarder+Cellular.swift`.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects start with `.start(queue: queue)` so
/// their callbacks fire on `queue`, and the public API funnels through
/// `queue.async`. Lifecycle transitions are pushed to the MainActor UI through
/// the `@Sendable` callbacks; nothing on the per-packet path touches MainActor.
final class PhoneRelayForwarder: @unchecked Sendable {
    let metrics = RelayMetrics()

    let queue = DispatchQueue(label: "CellTunnelPhone.RelayPlane")
    var macConnection: NWConnection?
    var cellularConnection: NWConnection?
    var endpointFamily = RelayAddressFamily.ipv4
    var state = WireGuardDatagramRelayState.stopped
    var pendingDatagrams: [WireGuardDatagram] = []
    var configuredEndpoint: RelayEndpoint?

    // The in-flight candidate dial the manager asked for. The browser discovers
    // the agent on the chosen path class and the connection is the make half of
    // make-before-break; neither becomes the live link until promotion. Touched
    // only on `queue`, shared with `PhoneRelayForwarder+Link.swift`.
    var pendingBrowser: NWBrowser?
    var pendingConnection: NWConnection?
    var pendingStrategy: RelayDialStrategy?
    var establishTimer: DispatchSourceTimer?

    // Bounds the datagrams handed to the cellular socket but not yet accepted, so
    // an upload faster than the cellular uplink cannot balloon the OS send buffer.
    // Without this cap the buffer grows under upload load, inflating latency and
    // throttling the upload; dropping past the cap lets WireGuard pace itself.
    let outstandingCellularSends = Atomic<Int>(0)

    // Once-only flags so each boundary function logs context exactly once
    // (satisfying the boundary-log audit) instead of logging per datagram.
    let didLogMacReceive = Atomic<Bool>(false)
    let didLogMacSend = Atomic<Bool>(false)
    let didLogCellularReceive = Atomic<Bool>(false)
    let didLogCellularSend = Atomic<Bool>(false)

    var onStateChange: (@Sendable (WireGuardDatagramRelayState) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onPeerChange: (@Sendable (String?) -> Void)?

    // The transport manager wires these to learn when a candidate is ready to
    // promote, when a candidate dial gave up, and when the active link dropped.
    var onCandidateReady: (@Sendable (RelayDialStrategy) -> Void)?
    var onCandidateFailed: (@Sendable (RelayDialStrategy) -> Void)?
    var onActiveDropped: (@Sendable () -> Void)?

    // MARK: - Public API (MainActor callers funnel onto the relay queue)

    func start() {
        logger.notice("phone relay forwarder ready, awaiting transport manager")
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

    func stop() {
        logger.notice("phone relay forwarder stop requested")
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    // MARK: - Active link drop handling (queue-only)

    func handleMacConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .failed(let error):
            logger.error(
                "phone relay mac connection failed error=\(error.localizedDescription, privacy: .public)"
            )
            onError?(error.localizedDescription)
            connection.cancel()
            clearActiveMacConnection(connection)
        case .cancelled:
            clearActiveMacConnection(connection)
        default:
            break
        }
    }

    private func handleMacReceiveError(_ error: NWError, connection: NWConnection) {
        logger.error(
            "phone relay mac receive failed error=\(error.localizedDescription, privacy: .public)"
        )
        onError?(error.localizedDescription)
        connection.cancel()
        clearActiveMacConnection(connection)
    }

    private func clearActiveMacConnection(_ connection: NWConnection) {
        guard macConnection === connection else {
            return
        }
        macConnection = nil
        onPeerChange?(nil)
        logger.notice("phone relay active link cleared")
        onActiveDropped?()
    }

    // MARK: - Upload hot path (Mac -> server), queue-only, no actor hop

    func receiveFromMac(on connection: NWConnection) {
        if didLogMacReceive.compareExchange(
            expected: false, desired: true, ordering: .relaxed
        ).exchanged {
            logger.notice("phone relay mac receive loop armed")
        }
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else {
                return
            }
            guard macConnection === connection else {
                return
            }
            if let error {
                handleMacReceiveError(error, connection: connection)
                return
            }
            if let data, !data.isEmpty {
                metrics.addBytesIn(UInt64(data.count))
                metrics.addDatagramsFromMac()
                sendToServer(data)
            }
            receiveFromMac(on: connection)
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

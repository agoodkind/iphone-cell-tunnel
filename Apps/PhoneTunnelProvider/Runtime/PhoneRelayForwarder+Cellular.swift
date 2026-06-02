//
//  PhoneRelayForwarder+Cellular.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .relay)
private let pendingWireGuardDatagramLimit = 64
private let nanosecondsPerMillisecond = 1_000_000.0
// The allowance is logged only when it crosses this multiple from the last logged
// value, so a steadily adjusting controller does not log per datagram.
private let allowanceLogBand = 2

// Renders an interface type for diagnostics so the log shows which physical path
// the relay used (cellular for egress, wiredEthernet/other for the Mac link).
func describeInterfaceType(_ type: NWInterface.InterfaceType) -> String {
    switch type {
    case .other:
        return "other"
    case .wifi:
        return "wifi"
    case .cellular:
        return "cellular"
    case .wiredEthernet:
        return "wiredEthernet"
    case .loopback:
        return "loopback"
    @unknown default:
        return "unknown"
    }
}

func cellularWireGuardUDPState(for state: NWConnection.State) -> CellularWireGuardUDPState {
    switch state {
    case .setup, .preparing, .waiting:
        return .connecting
    case .ready:
        return .ready
    case .failed:
        return .failed
    case .cancelled:
        return .stopped
    @unknown default:
        return .connecting
    }
}

func cellularWireGuardUDPErrorMessage(for state: NWConnection.State) -> String? {
    if case .failed(let error) = state {
        return error.localizedDescription
    }
    return nil
}

/// The cellular-facing half of the relay data plane. Every method here runs only
/// on `PhoneRelayForwarder.queue`, the same serial queue the class confines all
/// of its state to. The four methods the class calls across this file boundary
/// (`applyEndpointOnQueue`, `stopOnQueue`, `cellularSend`, `bufferPendingDatagram`)
/// are internal; the rest are private to this file.
extension PhoneRelayForwarder {
    // MARK: - Download hot path (server -> Mac), queue-only, no actor hop

    private func receiveFromCellular(on connection: NWConnection) {
        if didLogCellularReceive.compareExchange(
            expected: false, desired: true, ordering: .relaxed
        ).exchanged {
            logger.notice("cellular relay receive loop armed")
        }
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else {
                return
            }
            guard cellularConnection === connection else {
                logger.debug("cellular relay stale receive ignored")
                return
            }
            if let error {
                logger.error(
                    "cellular relay receive failed error=\(error.localizedDescription, privacy: .public)"
                )
                fail(error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                metrics.addDatagramsFromServer()
                forwardCellularDatagram(data)
            }
            receiveFromCellular(on: connection)
        }
    }

    private func forwardCellularDatagram(_ data: Data) {
        do {
            let datagram = try WireGuardDatagram(data: data, addressFamily: endpointFamily)
            sendToMac(datagram.data)
        } catch {
            logger.error(
                "cellular relay datagram rejected error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendToMac(_ data: Data) {
        guard let mac = egressConnection else {
            metrics.addDropped()
            logger.error("phone relay datagram to mac dropped error=no-live-egress-link")
            return
        }
        if didLogMacSend.compareExchange(
            expected: false, desired: true, ordering: .relaxed
        ).exchanged {
            logger.notice("phone relay mac send path active")
        }
        let metrics = self.metrics
        let bytesOut = UInt64(data.count)
        mac.send(
            content: data,
            completion: .contentProcessed { [weak self, weak mac] error in
                if let error {
                    metrics.addDropped()
                    logger.error(
                        "phone relay datagram to mac failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    // A send failure on the carrying link is the reliable signal a
                    // UDP path went away, since the connection state may never reach
                    // .failed. Drop the link so the carrying choice moves at once.
                    if let self, let mac {
                        failMacSend(on: mac)
                    }
                    return
                }
                metrics.addBytesOut(bytesOut)
                metrics.addDatagramsToMac()
            }
        )
    }

    func cellularSend(_ datagram: WireGuardDatagram) {
        guard let connection = cellularConnection else {
            metrics.addDropped()
            logger.error("cellular relay send failed error=not-started")
            return
        }
        if didLogCellularSend.compareExchange(
            expected: false, desired: true, ordering: .relaxed
        ).exchanged {
            logger.notice("cellular relay send path active")
        }
        if outstandingCellularSends >= cellularSendWindow.allowance {
            metrics.addDropped()
            cellularWindowSaturated = true
            return
        }
        outstandingCellularSends += 1
        let sentAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let metrics = self.metrics
        connection.send(
            content: datagram.data,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }
                outstandingCellularSends -= 1
                if let error {
                    metrics.addDropped()
                    logger.error(
                        "cellular relay send failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                let waitNanoseconds = DispatchTime.now().uptimeNanoseconds - sentAtNanoseconds
                recordCellularSendWait(Double(waitNanoseconds) / nanosecondsPerMillisecond)
                metrics.addDatagramsToServer()
            }
        )
    }

    // Folds the measured send-buffer wait into the window that sizes the in-flight
    // allowance, and logs the allowance only when it crosses a doubling band from
    // the last logged value, so the controller is observable without a per-datagram
    // log flood.
    private func recordCellularSendWait(_ milliseconds: Double) {
        cellularSendWindow.recordWait(
            milliseconds: milliseconds, windowLimited: cellularWindowSaturated
        )
        cellularWindowSaturated = false
        let allowance = cellularSendWindow.allowance
        let grewPastBand = allowance >= loggedSendAllowance * allowanceLogBand
        let shrankPastBand = allowance * allowanceLogBand <= loggedSendAllowance
        guard loggedSendAllowance == 0 || grewPastBand || shrankPastBand else {
            return
        }
        loggedSendAllowance = allowance
        logger.notice(
            """
            cellular send window allowance=\(allowance, privacy: .public) \
            smoothedWaitMs=\(Int(self.cellularSendWindow.smoothedWaitMilliseconds), privacy: .public)
            """
        )
    }

    // MARK: - Cellular connection lifecycle (queue-only)

    func applyEndpointOnQueue(_ endpoint: RelayEndpoint) {
        let endpointUnchanged = configuredEndpoint == endpoint
        let alreadyActive = state == .ready || state == .connecting
        if endpointUnchanged, alreadyActive {
            logger.notice("phone relay server endpoint update ignored (unchanged and active)")
            return
        }
        configuredEndpoint = endpoint
        guard !endpoint.host.isEmpty else {
            logger.error("cellular relay start failed error=missing-server-endpoint")
            fail(WireGuardDatagramRelayError.missingServerEndpoint.localizedDescription)
            return
        }
        guard let serverPort = NWEndpoint.Port(rawValue: endpoint.port) else {
            logger.error(
                "cellular relay start failed port=\(endpoint.port, privacy: .public)"
            )
            fail(WireGuardDatagramRelayError.invalidServerPort(endpoint.port).localizedDescription)
            return
        }

        cellularConnection?.cancel()
        cellularConnection = nil
        pendingDatagrams.removeAll(keepingCapacity: true)
        endpointFamily = endpoint.addressFamily

        let parameters = NWParameters.udp
        // bestEffort is the throughput-favoring default and the service class that
        // enables cellular network slicing when no other class is set. The path is
        // left able to use expensive and constrained networks (defaults), so the
        // relay is never opted out of the user's "Allow More Data on 5G" data mode.
        parameters.serviceClass = .bestEffort
        #if targetEnvironment(simulator)
            logger.notice(
                "cellular relay simulator-mode: cellular gate skipped; egress uses host network"
            )
        #else
            parameters.requiredInterfaceType = .cellular
        #endif
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host), port: serverPort, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] nwState in
            guard let connection else {
                return
            }
            self?.handleCellularStateUpdate(nwState, connection: connection)
        }
        cellularConnection = connection
        state = .connecting
        onStateChange?(state)
        logger.notice(
            """
            cellular relay starting endpointFamily=\(endpoint.addressFamily.rawValue, privacy: .public) \
            port=\(endpoint.port, privacy: .public)
            """
        )
        connection.start(queue: queue)
        receiveFromCellular(on: connection)
    }

    private func handleCellularStateUpdate(
        _ nwState: NWConnection.State, connection: NWConnection
    ) {
        guard cellularConnection === connection else {
            return
        }
        logger.notice(
            "cellular relay state changed state=\(String(describing: nwState), privacy: .public)"
        )
        if case .ready = nwState {
            logCellularPath(connection)
        }
        applyCellularState(
            cellularWireGuardUDPState(for: nwState),
            errorMessage: cellularWireGuardUDPErrorMessage(for: nwState)
        )
    }

    // Logs the cellular path the relay egresses on, including whether the system
    // marks it expensive or constrained. Constrained reflects the user's Data
    // Mode choice ("Allow More Data on 5G" / Low Data Mode); a constrained path
    // is the system signal that 5G throughput is being held back.
    private func logCellularPath(_ connection: NWConnection) {
        guard let path = connection.currentPath else {
            logger.notice("cellular relay path unavailable")
            return
        }
        let interfaces = path.availableInterfaces
            .map { "\($0.name):\(describeInterfaceType($0.type))" }
            .joined(separator: ",")
        logger.notice(
            """
            cellular relay path expensive=\(path.isExpensive, privacy: .public) \
            constrained=\(path.isConstrained, privacy: .public) \
            interfaces=\(interfaces, privacy: .public)
            """
        )
    }

    private func applyCellularState(
        _ udpState: CellularWireGuardUDPState, errorMessage: String?
    ) {
        switch udpState {
        case .stopped:
            pendingDatagrams.removeAll(keepingCapacity: false)
            state = .stopped
        case .connecting:
            state = .connecting
        case .ready:
            state = .ready
            flushPendingDatagrams()
        case .failed:
            pendingDatagrams.removeAll(keepingCapacity: false)
            state = .failed
            fail(errorMessage ?? "cellular WireGuard UDP connection failed")
        }
        onStateChange?(state)
        logger.notice(
            """
            cellular relay state applied udpState=\(udpState.rawValue, privacy: .public) \
            relayState=\(self.state.rawValue, privacy: .public)
            """
        )
    }

    func bufferPendingDatagram(_ datagram: WireGuardDatagram) {
        guard pendingDatagrams.count < pendingWireGuardDatagramLimit else {
            metrics.addDropped()
            logger.error(
                "phone relay pending queue full count=\(self.pendingDatagrams.count, privacy: .public)"
            )
            return
        }
        pendingDatagrams.append(datagram)
        logger.notice(
            "phone relay buffered datagram while connecting pendingCount=\(self.pendingDatagrams.count, privacy: .public)"
        )
    }

    private func flushPendingDatagrams() {
        guard !pendingDatagrams.isEmpty else {
            return
        }
        logger.notice(
            "phone relay flushing pending datagrams count=\(self.pendingDatagrams.count, privacy: .public)"
        )
        let datagrams = pendingDatagrams
        pendingDatagrams.removeAll(keepingCapacity: true)
        for datagram in datagrams {
            cellularSend(datagram)
        }
    }

    private func fail(_ message: String) {
        logger.error("phone relay forwarder failed error=\(message, privacy: .public)")
        onError?(message)
    }

    func stopOnQueue() {
        for link in macLinks.values {
            link.connection.cancel()
        }
        macLinks.removeAll()
        egressConnection = nil
        egressInterfaceName = nil
        preferredInterface = nil
        hasLivePeer = false
        cellularConnection?.cancel()
        cellularConnection = nil
        pendingDatagrams.removeAll(keepingCapacity: false)
        outstandingCellularSends = 0
        cellularSendWindow = CellularSendWindow()
        loggedSendAllowance = 0
        cellularWindowSaturated = false
        configuredEndpoint = nil
        state = .stopped
        onPeerChange?(nil)
        onStateChange?(state)
        logger.notice("phone relay forwarder stopped")
    }
}

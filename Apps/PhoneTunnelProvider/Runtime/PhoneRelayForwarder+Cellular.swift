import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .relay)
private let pendingWireGuardDatagramLimit = 64

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
        guard let mac = macConnection else {
            metrics.addDropped()
            logger.error("phone relay datagram to mac dropped error=no-current-mac-endpoint")
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
            completion: .contentProcessed { error in
                if let error {
                    metrics.addDropped()
                    logger.error(
                        "phone relay datagram to mac failed error=\(error.localizedDescription, privacy: .public)"
                    )
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
        let metrics = self.metrics
        connection.send(
            content: datagram.data,
            completion: .contentProcessed { error in
                if let error {
                    metrics.addDropped()
                    logger.error(
                        "cellular relay send failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                metrics.addDatagramsToServer()
            }
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
        applyCellularState(
            cellularWireGuardUDPState(for: nwState),
            errorMessage: cellularWireGuardUDPErrorMessage(for: nwState)
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
        macConnection?.cancel()
        macConnection = nil
        cellularConnection?.cancel()
        cellularConnection = nil
        listener?.cancel()
        listener = nil
        pendingDatagrams.removeAll(keepingCapacity: false)
        configuredEndpoint = nil
        state = .stopped
        onPeerChange?(nil)
        onListenerReady?(nil)
        onStateChange?(state)
        logger.notice("phone relay forwarder stopped")
    }
}

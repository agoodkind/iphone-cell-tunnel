import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .relay)
private let pendingWireGuardDatagramLimit = 64

enum WireGuardDatagramRelayState: String, Sendable {
    case stopped
    case waitingForHandshake
    case connecting
    case ready
    case failed

    var displayName: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .waitingForHandshake:
            return "Waiting for endpoint"
        case .connecting:
            return "Connecting"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }
}

enum WireGuardDatagramRelayError: LocalizedError {
    case missingServerEndpoint
    case invalidServerPort(UInt16)
    case udpConnectionUnavailable

    var errorDescription: String? {
        switch self {
        case .missingServerEndpoint:
            return "WireGuard server endpoint is not configured"
        case .invalidServerPort(let port):
            return "WireGuard server port is invalid: \(port)"
        case .udpConnectionUnavailable:
            return "cellular WireGuard UDP connection is unavailable"
        }
    }
}

@MainActor
final class WireGuardDatagramRelaySession {
    private let udpClient: CellularWireGuardUDPClient
    private(set) var state = WireGuardDatagramRelayState.stopped
    private var pendingDatagrams: [WireGuardDatagram] = []

    var datagramHandler: ((WireGuardDatagram) -> Void)?
    var errorHandler: ((String) -> Void)?

    init(udpClient: CellularWireGuardUDPClient = CellularWireGuardUDPClient()) {
        self.udpClient = udpClient
    }

    func prepareForHandshake() {
        logger.notice("wireguard datagram relay waiting for handshake")
        state = .waitingForHandshake
        udpClient.datagramHandler = { [weak self] datagram in
            Task { @MainActor [weak self] in
                self?.datagramHandler?(datagram)
            }
        }
        udpClient.stateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.applyUDPState(state)
            }
        }
        udpClient.errorHandler = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.state = .failed
                self?.errorHandler?(message)
                logger.error("wireguard datagram relay failed error=\(message, privacy: .public)")
            }
        }
    }

    func start(endpoint: RelayEndpoint) throws {
        logger.notice(
            """
            wireguard datagram relay starting endpointFamily=\(endpoint.addressFamily.rawValue, privacy: .public) \
            hostConfigured=\(!endpoint.host.isEmpty, privacy: .public) port=\(endpoint.port, privacy: .public)
            """
        )
        do {
            state = .connecting
            pendingDatagrams.removeAll(keepingCapacity: true)
            try udpClient.start(endpoint: endpoint)
            logger.notice("wireguard datagram relay connecting")
        } catch {
            state = .failed
            logger.error(
                """
                wireguard datagram relay start failed \
                error=\(error.localizedDescription, privacy: .public) recovery=reject-datagrams
                """
            )
            throw error
        }
    }

    func sendToServer(_ datagram: WireGuardDatagram) throws {
        if state == .connecting {
            try bufferPendingDatagram(datagram)
            return
        }

        guard state == .ready else {
            logger.error(
                """
                wireguard datagram relay send rejected state=\(self.state.rawValue, privacy: .public) \
                recovery=send-relay-error
                """
            )
            throw WireGuardDatagramRelayError.udpConnectionUnavailable
        }

        try udpClient.send(datagram: datagram)
    }

    func stop() {
        logger.notice(
            "wireguard datagram relay stopping state=\(self.state.rawValue, privacy: .public)")
        udpClient.stop()
        udpClient.datagramHandler = nil
        udpClient.stateHandler = nil
        udpClient.errorHandler = nil
        datagramHandler = nil
        errorHandler = nil
        pendingDatagrams.removeAll(keepingCapacity: false)
        state = .stopped
        logger.notice("wireguard datagram relay stopped")
    }

    private func applyUDPState(_ udpState: CellularWireGuardUDPState) {
        switch udpState {
        case .stopped:
            pendingDatagrams.removeAll(keepingCapacity: false)
            state = .stopped
        case .connecting:
            state = .connecting
        case .ready:
            state = .ready
            flushPendingDatagramsIfNeeded()
        case .failed:
            pendingDatagrams.removeAll(keepingCapacity: false)
            state = .failed
        }
        logger.notice(
            """
            wireguard datagram relay udp state applied udpState=\(udpState.rawValue, privacy: .public) \
            relayState=\(self.state.rawValue, privacy: .public)
            """
        )
    }

    private func bufferPendingDatagram(_ datagram: WireGuardDatagram) throws {
        guard pendingDatagrams.count < pendingWireGuardDatagramLimit else {
            logger.error(
                """
                wireguard datagram relay pending queue full count=\(self.pendingDatagrams.count, privacy: .public) \
                recovery=reject-datagram
                """
            )
            throw WireGuardDatagramRelayError.udpConnectionUnavailable
        }

        pendingDatagrams.append(datagram)
        logger.notice(
            """
            wireguard datagram relay buffered datagram while connecting \
            pendingCount=\(self.pendingDatagrams.count, privacy: .public) bytes=\(datagram.data.count, privacy: .public)
            """
        )
    }

    private func flushPendingDatagramsIfNeeded() {
        guard !pendingDatagrams.isEmpty else {
            return
        }

        logger.notice(
            "wireguard datagram relay flushing pending datagrams count=\(self.pendingDatagrams.count, privacy: .public)"
        )
        let datagrams = pendingDatagrams
        pendingDatagrams.removeAll(keepingCapacity: true)

        for datagram in datagrams {
            do {
                try udpClient.send(datagram: datagram)
            } catch {
                state = .failed
                reportError(error.localizedDescription)
                logger.error(
                    """
                    wireguard datagram relay pending flush failed \
                    error=\(error.localizedDescription, privacy: .public)
                    """
                )
                return
            }
        }
    }

    private func reportError(_ message: String) {
        errorHandler?(message)
        logger.error("wireguard datagram relay failed error=\(message, privacy: .public)")
    }
}

enum CellularWireGuardUDPState: String, Sendable {
    case stopped
    case connecting
    case ready
    case failed
}

@MainActor
final class CellularWireGuardUDPClient {
    private let queue = DispatchQueue(label: "CellTunnelPhone.WireGuardUDP")
    private var connection: NWConnection?
    private var endpointFamily = RelayAddressFamily.ipv4
    var datagramHandler: ((WireGuardDatagram) -> Void)?
    var stateHandler: ((CellularWireGuardUDPState) -> Void)?
    var errorHandler: ((String) -> Void)?

    func start(endpoint: RelayEndpoint) throws {
        guard !endpoint.host.isEmpty else {
            logger.error(
                "cellular wireguard udp start failed error=missing-server-endpoint recovery=fail-closed"
            )
            throw WireGuardDatagramRelayError.missingServerEndpoint
        }

        guard let wireGuardPort = NWEndpoint.Port(rawValue: endpoint.port) else {
            logger.error(
                "cellular wireguard udp start failed port=\(endpoint.port, privacy: .public) recovery=fail-closed"
            )
            throw WireGuardDatagramRelayError.invalidServerPort(endpoint.port)
        }

        stop()
        endpointFamily = endpoint.addressFamily
        let parameters = NWParameters.udp
        #if targetEnvironment(simulator)
            logger.notice(
                "cellular wireguard udp simulator-mode: cellular gate skipped; egress uses host network"
            )
        #else
            parameters.requiredInterfaceType = .cellular
        #endif
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host), port: wireGuardPort, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            let description = String(describing: state)
            let udpState = cellularWireGuardUDPState(for: state)
            let errorMessage = cellularWireGuardUDPErrorMessage(for: state)
            logger.notice(
                "cellular wireguard udp state changed state=\(description, privacy: .public)")
            Task { @MainActor [weak self, weak connection] in
                self?.handleStateUpdate(
                    udpState,
                    errorMessage: errorMessage,
                    connection: connection
                )
            }
        }
        self.connection = connection
        logger.notice(
            """
            cellular wireguard udp starting endpointFamily=\(endpoint.addressFamily.rawValue, privacy: .public) \
            hostConfigured=true port=\(endpoint.port, privacy: .public)
            """
        )
        stateHandler?(.connecting)
        connection.start(queue: queue)
        receive(on: connection)
    }

    func send(datagram: WireGuardDatagram) throws {
        guard let connection else {
            logger.error(
                "cellular wireguard udp send failed error=not-started recovery=drop-datagram")
            throw WireGuardDatagramRelayError.udpConnectionUnavailable
        }

        connection.send(
            content: datagram.data,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let error else {
                    return
                }
                logger.error(
                    "cellular wireguard udp send failed error=\(error.localizedDescription, privacy: .public)"
                )
                Task { @MainActor [weak self, weak connection] in
                    self?.handleSendFailure(
                        error.localizedDescription,
                        connection: connection
                    )
                }
            })
    }

    func stop() {
        logger.notice("cellular wireguard udp stopping")
        connection?.cancel()
        connection = nil
        stateHandler?(.stopped)
        logger.notice("cellular wireguard udp stopped")
    }

    private func handle(connectionState state: CellularWireGuardUDPState, errorMessage: String?) {
        switch state {
        case .connecting:
            stateHandler?(.connecting)
        case .ready:
            stateHandler?(.ready)
        case .failed:
            stateHandler?(.failed)
            reportError(errorMessage ?? "cellular WireGuard UDP connection failed")
        case .stopped:
            stateHandler?(.stopped)
        }
    }

    private func reportError(_ message: String) {
        logger.error("cellular wireguard udp error reported error=\(message, privacy: .public)")
        errorHandler?(message)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            Task { @MainActor [weak self, weak connection] in
                self?.handleReceiveResult(
                    data: data,
                    error: error,
                    connection: connection
                )
            }
        }
    }

    private func handleStateUpdate(
        _ state: CellularWireGuardUDPState,
        errorMessage: String?,
        connection: NWConnection?
    ) {
        guard
            guardCurrentConnection(
                connection,
                staleMessage: "cellular wireguard udp stale state update ignored"
            )
        else {
            return
        }
        handle(connectionState: state, errorMessage: errorMessage)
    }

    private func handleSendFailure(_ message: String, connection: NWConnection?) {
        guard
            guardCurrentConnection(
                connection,
                staleMessage: "cellular wireguard udp stale send failure ignored"
            )
        else {
            return
        }
        reportError(message)
    }

    private func handleReceiveResult(
        data: Data?,
        error: NWError?,
        connection: NWConnection?
    ) {
        guard
            guardCurrentConnection(
                connection,
                staleMessage: "cellular wireguard udp stale receive loop ignored"
            )
        else {
            return
        }

        if let error {
            logger.error(
                "cellular wireguard udp receive failed error=\(error.localizedDescription, privacy: .public)"
            )
            reportError(error.localizedDescription)
            return
        }

        if let data, !data.isEmpty {
            forwardReceivedDatagram(data, connection: connection)
        }

        guard let connection else {
            logger.notice("cellular wireguard udp receive stopped")
            return
        }
        receive(on: connection)
    }

    private func forwardReceivedDatagram(_ data: Data, connection: NWConnection?) {
        guard
            guardCurrentConnection(
                connection,
                staleMessage: "cellular wireguard udp stale datagram ignored"
            )
        else {
            return
        }

        do {
            let datagram = try WireGuardDatagram(data: data, addressFamily: endpointFamily)
            datagramHandler?(datagram)
        } catch {
            logger.error(
                """
                cellular wireguard udp datagram rejected \
                error=\(error.localizedDescription, privacy: .public) recovery=drop-datagram
                """
            )
        }
    }

    private func guardCurrentConnection(_ connection: NWConnection?, staleMessage: String) -> Bool {
        guard isCurrentConnection(connection) else {
            logger.debug("\(staleMessage, privacy: .public)")
            return false
        }
        return true
    }

    private func isCurrentConnection(_ connection: NWConnection?) -> Bool {
        guard let connection else {
            return false
        }
        return self.connection === connection
    }
}

private func cellularWireGuardUDPState(for state: NWConnection.State) -> CellularWireGuardUDPState {
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

private func cellularWireGuardUDPErrorMessage(for state: NWConnection.State) -> String? {
    if case .failed(let error) = state {
        return error.localizedDescription
    }
    return nil
}

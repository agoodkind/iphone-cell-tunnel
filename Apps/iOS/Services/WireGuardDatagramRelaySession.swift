import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .relay)

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
                logger.debug(
                    "wireguard datagram relay received hosted datagram bytes=\(datagram.data.count, privacy: .public)"
                )
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
        guard state == .ready else {
            logger.error(
                """
                wireguard datagram relay send rejected state=\(self.state.rawValue, privacy: .public) \
                recovery=send-relay-error
                """
            )
            throw WireGuardDatagramRelayError.udpConnectionUnavailable
        }

        logger.debug(
            """
            wireguard datagram relay forwarding to hosted server \
            endpointFamily=\(datagram.addressFamily.rawValue, privacy: .public) bytes=\(datagram.data.count, privacy: .public)
            """
        )
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
        state = .stopped
        logger.notice("wireguard datagram relay stopped")
    }

    private func applyUDPState(_ udpState: CellularWireGuardUDPState) {
        switch udpState {
        case .stopped:
            state = .stopped
        case .connecting:
            state = .connecting
        case .ready:
            state = .ready
        case .failed:
            state = .failed
        }
        logger.notice(
            """
            wireguard datagram relay udp state applied udpState=\(udpState.rawValue, privacy: .public) \
            relayState=\(self.state.rawValue, privacy: .public)
            """
        )
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
        parameters.requiredInterfaceType = .cellular
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host), port: wireGuardPort, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            let description = String(describing: state)
            let udpState = cellularWireGuardUDPState(for: state)
            let errorMessage = cellularWireGuardUDPErrorMessage(for: state)
            logger.notice(
                "cellular wireguard udp state changed state=\(description, privacy: .public)")
            Task { @MainActor [weak self] in
                self?.handle(connectionState: udpState, errorMessage: errorMessage)
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

        logger.debug(
            "cellular wireguard udp sending datagram bytes=\(datagram.data.count, privacy: .public)"
        )
        connection.send(
            content: datagram.data,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    logger.error(
                        "cellular wireguard udp send failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    Task { @MainActor [weak self] in
                        self?.reportError(error.localizedDescription)
                    }
                    return
                }

                logger.debug(
                    "cellular wireguard udp send completed bytes=\(datagram.data.count, privacy: .public)"
                )
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
        logger.debug("cellular wireguard udp receive scheduled")
        connection.receiveMessage { [weak self, weak connection] data, _, isComplete, error in
            if let error {
                logger.error(
                    "cellular wireguard udp receive failed error=\(error.localizedDescription, privacy: .public)"
                )
                Task { @MainActor [weak self] in
                    self?.reportError(error.localizedDescription)
                }
                return
            }

            if let data, !data.isEmpty {
                logger.debug(
                    "cellular wireguard udp received datagram bytes=\(data.count, privacy: .public)"
                )
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    do {
                        let datagram = try WireGuardDatagram(
                            data: data, addressFamily: endpointFamily)
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
            }

            if isComplete {
                logger.debug("cellular wireguard udp message completed")
            }

            guard let connection else {
                logger.notice("cellular wireguard udp receive stopped")
                return
            }

            Task { @MainActor [weak self] in
                self?.receive(on: connection)
            }
        }
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

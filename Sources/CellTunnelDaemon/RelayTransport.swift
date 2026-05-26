import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

enum RelayTransportError: LocalizedError {
    case alreadyConnected
    case notConnected
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "relay transport already connected"
        case .notConnected:
            return "relay transport not connected"
        case .invalidEndpoint:
            return "relay transport endpoint invalid"
        }
    }
}

final class RelayTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.goodkind.celltunneld.relay")
    private var connection: NWConnection?
    var onReceive: ((Data) -> Void)?

    func connect(to endpoint: NWEndpoint) throws {
        guard connection == nil else {
            throw RelayTransportError.alreadyConnected
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        let nwConnection = NWConnection(to: endpoint, using: parameters)
        nwConnection.stateUpdateHandler = { state in
            logger.notice(
                """
                relay transport state=\(String(describing: state), privacy: .public) \
                endpoint=\(String(describing: endpoint), privacy: .public)
                """
            )
        }
        nwConnection.start(queue: queue)
        connection = nwConnection
        receiveLoop(on: nwConnection)
        logger.notice(
            "relay transport connecting endpoint=\(String(describing: endpoint), privacy: .public)"
        )
    }

    func send(_ datagram: Data) {
        guard let activeConnection = connection else {
            logger.error(
                """
                relay transport send failed error=not-connected \
                bytes=\(datagram.count, privacy: .public)
                """
            )
            return
        }
        activeConnection.send(
            content: datagram,
            completion: .contentProcessed { error in
                guard let error else {
                    return
                }
                logger.error(
                    """
                    relay transport send failed \
                    error=\(error.localizedDescription, privacy: .public)
                    """
                )
            }
        )
    }

    func disconnect() {
        guard let activeConnection = connection else {
            return
        }
        connection = nil
        activeConnection.cancel()
        logger.notice("relay transport disconnected")
    }

    private func receiveLoop(on activeConnection: NWConnection) {
        activeConnection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                onReceive?(data)
            }
            if let error {
                logger.error(
                    "relay transport receive failed error=\(error.localizedDescription, privacy: .public)"
                )
                return
            }
            receiveLoop(on: activeConnection)
        }
    }
}

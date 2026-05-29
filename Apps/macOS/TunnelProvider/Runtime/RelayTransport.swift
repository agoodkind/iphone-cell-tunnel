import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

enum RelayTransportError: LocalizedError {
    case alreadyConnected
    case invalidEndpoint
    case notConnected

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "relay transport already connected"
        case .invalidEndpoint:
            return "relay transport endpoint invalid"
        case .notConnected:
            return "relay transport not connected"
        }
    }
}

final class RelayTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.goodkind.celltunnel.relay")
    private let metrics: RelayMetrics
    private var connection: NWConnection?
    var onReceive: ((Data) -> Void)?

    init(metrics: RelayMetrics) {
        self.metrics = metrics
    }

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
            metrics.addDropped()
            logger.error(
                """
                relay transport send failed error=not-connected \
                bytes=\(datagram.count, privacy: .public)
                """
            )
            return
        }
        let metrics = self.metrics
        activeConnection.send(
            content: datagram,
            completion: .contentProcessed { error in
                guard let error else {
                    return
                }
                metrics.addDropped()
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
                if let onReceive {
                    onReceive(data)
                } else {
                    metrics.addDropped()
                }
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

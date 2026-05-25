import CellTunnelLog
import Network

private let logger = CellTunnelLog.logger(category: .relay)

extension PhoneRelayController {
    func replacePeerConnections(with peerConnection: PhonePeerConnection) {
        logger.notice(
            "relay peer replacement starting activeConnections=\(self.connections.count, privacy: .public)"
        )
        for existingConnection in self.connections {
            existingConnection.connection.cancel()
        }
        self.connections = [peerConnection]
        logger.notice("relay peer replacement completed activeConnections=1")
    }

    func handlePeerFailure(_ error: NWError, connection: NWConnection) {
        self.lastError = error.localizedDescription
        logger.error("relay peer failed error=\(error.localizedDescription, privacy: .public)")
        connection.cancel()
        removePeerConnection(connection)
    }

    func removePeerConnection(_ connection: NWConnection) {
        self.connections.removeAll { $0.connection === connection }
        guard self.connections.isEmpty else {
            return
        }

        self.connectedPeerName = nil
        self.wireGuardSession.datagramHandler = nil
        self.wireGuardSession.errorHandler = nil
    }
}

import CellTunnelLog
import Network

private let logger = CellTunnelLog.logger(category: .relay)

extension PhoneRelayController {
    func adoptMacConnection(_ connection: NWConnection) {
        if let existing = currentMacConnection, existing !== connection {
            logger.notice("relay current mac endpoint replacing previous connection")
            existing.cancel()
        }
        currentMacConnection = connection
        connectedPeerName = "Mac"
    }

    func handle(connectionState state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .failed(let error):
            handleMacReceiveError(error, connection: connection)
        case .cancelled:
            if currentMacConnection === connection {
                logger.notice("relay current mac endpoint cancelled")
                currentMacConnection = nil
                connectedPeerName = nil
            }
        default:
            break
        }
    }

    func handleMacReceiveError(_ error: NWError, connection: NWConnection) {
        lastError = error.localizedDescription
        logger.error(
            "relay mac connection failed error=\(error.localizedDescription, privacy: .public)"
        )
        connection.cancel()
        if currentMacConnection === connection {
            currentMacConnection = nil
            connectedPeerName = nil
        }
    }
}

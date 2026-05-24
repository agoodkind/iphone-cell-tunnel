import CellTunnelCore
import CellTunnelLog
import Network

private let logger = CellTunnelLog.logger(category: .relay)

final class PhonePeerConnection: @unchecked Sendable {
    let connection: NWConnection
    var frameBuffer = RelayFrameBuffer()
    var lastAddressFamily = RelayAddressFamily.ipv4

    init(connection: NWConnection) {
        self.connection = connection
        logger.notice("phone peer connection initialized")
    }
}

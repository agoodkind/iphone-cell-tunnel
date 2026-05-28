import CellTunnelLog
import Foundation
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .relay)

final class WireGuardRelayBind: WireGuardRelayBindBridge, @unchecked Sendable {
    private let transport: RelayTransport
    private let lock = NSLock()
    private var injector: ((Data, String) -> Void)?

    init(transport: RelayTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] datagram in
            self?.deliverInbound(datagram)
        }
    }

    deinit {
        transport.onReceive = nil
    }

    func send(data: Data, endpoint: String) {
        logger.debug(
            """
            relay bind send bytes=\(data.count, privacy: .public) \
            endpoint=\(endpoint, privacy: .public)
            """
        )
        transport.send(data)
    }

    func attach(injector: @escaping (Data, String) -> Void) {
        lock.lock()
        self.injector = injector
        lock.unlock()
    }

    func detach() {
        lock.lock()
        injector = nil
        lock.unlock()
    }

    // The peer endpoint string is informational because RelayTransport already
    // targets the iPhone relay; wireguard-go still needs a non-empty endpoint
    // string when injecting received datagrams so its bind layer accepts them.
    private static let inboundEndpoint = "0.0.0.0:0"

    private func deliverInbound(_ datagram: Data) {
        lock.lock()
        let activeInjector = injector
        lock.unlock()
        guard let activeInjector else {
            logger.error(
                "relay bind inbound dropped bytes=\(datagram.count, privacy: .public) reason=not-attached"
            )
            return
        }
        activeInjector(datagram, Self.inboundEndpoint)
    }
}

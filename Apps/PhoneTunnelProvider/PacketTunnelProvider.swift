import CellTunnelLog
import NetworkExtension

private let logger = CellTunnelLog.logger(category: .daemon)

// Step 1 of running the iPhone relay in the background: a minimal
// NEPacketTunnelProvider that brings up a tunnel session, installs a no-route
// tunnel so the phone's own traffic is not captured, and logs each lifecycle
// boundary. The relay data plane is not moved here yet; that comes later.
private let tunnelRemoteAddress = "127.0.0.1"
private let tunnelLocalAddress = "10.7.0.2"
private let tunnelLocalSubnetMask = "255.255.255.255"

// NEPacketTunnelProvider serializes the tunnel lifecycle callbacks, so the
// state mutated across start and stop is never touched concurrently.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    // Held so the stop can complete after teardown finishes; a full teardown
    // invokes it once the relay connections cancel. Storing it is also why the
    // override keeps the @escaping handler the superclass declares.
    private var stopCompletion: (() -> Void)?

    override init() {
        super.init()
        logger.notice("PhoneTunnelProvider initialized")
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let optionCount = options?.count ?? 0
        logger.notice(
            "tunnel start request received optionsCount=\(optionCount, privacy: .public)"
        )

        let ipv4Settings = NEIPv4Settings(
            addresses: [tunnelLocalAddress],
            subnetMasks: [tunnelLocalSubnetMask]
        )
        // No includedRoutes: the minimal provider only proves the session
        // starts, so it must not capture the phone's traffic.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
        settings.ipv4Settings = ipv4Settings

        logger.notice(
            """
            tunnel network settings prepared remote=\(tunnelRemoteAddress, privacy: .public) \
            local=\(tunnelLocalAddress, privacy: .public)
            """
        )
        self.setTunnelNetworkSettings(settings) { error in
            if let error {
                logger.error(
                    """
                    setTunnelNetworkSettings failed \
                    details=\(String(describing: error), privacy: .public) \
                    recovery=propagate-to-NE
                    """
                )
            } else {
                logger.notice("setTunnelNetworkSettings applied success=true")
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.notice(
            "tunnel stop request received reason=\(String(describing: reason), privacy: .public)"
        )
        stopCompletion = completionHandler
        finishStop()
    }

    private func finishStop() {
        stopCompletion?()
        stopCompletion = nil
        logger.notice("tunnel stop completion handler called")
    }
}

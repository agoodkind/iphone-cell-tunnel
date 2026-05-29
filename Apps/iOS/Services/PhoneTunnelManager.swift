#if DEBUG
    import CellTunnelLog
    import Foundation
    import NetworkExtension
    import Observation

    private let logger = CellTunnelLog.logger(category: .app)

    private let tunnelProviderBundleSuffix = ".Tunnel"
    private let tunnelServerAddress = "Cell Tunnel"
    private let tunnelLocalizedDescription = "Cell Tunnel"

    /// DEBUG-only driver for the iOS background tunnel session. It loads or
    /// creates a single `NETunnelProviderManager` pointing at the embedded
    /// `CellTunnelPhoneTunnel` app extension, then starts and stops the VPN
    /// session so a device test can confirm the provider's `startTunnel` runs.
    /// This does not move the relay data plane; it only proves the session.
    @MainActor
    @Observable
    final class PhoneTunnelManager {
        var statusDescription = PhoneTunnelManager.describe(.invalid)
        var lastError: String?

        private var manager: NETunnelProviderManager?
        private var statusObserver: NSObjectProtocol?

        // The provider bundle id nests under the host app: the app's own
        // bundle id with a ".Tunnel" suffix matches PHONE_PROVIDER_BUNDLE_ID.
        private var providerBundleIdentifier: String {
            (Bundle.main.bundleIdentifier ?? "") + tunnelProviderBundleSuffix
        }

        func start() async {
            logger.notice("ios tunnel start requested")
            lastError = nil
            do {
                let loadedManager = try await loadOrCreateManager()
                try await loadedManager.connection.startVPNTunnel()
                manager = loadedManager
                observeStatus(on: loadedManager.connection)
                updateStatus(from: loadedManager)
                logger.notice("ios tunnel startVPNTunnel returned")
            } catch {
                let message = String(describing: error)
                lastError = message
                logger.error(
                    """
                    ios tunnel start failed \
                    details=\(message, privacy: .public) recovery=surface-to-console
                    """
                )
            }
        }

        func stop() {
            logger.notice("ios tunnel stop requested")
            guard let manager else {
                logger.notice("ios tunnel stop ignored because no manager is loaded")
                return
            }
            manager.connection.stopVPNTunnel()
            updateStatus(from: manager)
        }

        // Reuses the first manager that already targets this provider bundle id,
        // otherwise builds a fresh one. Either way it persists an enabled
        // NETunnelProviderProtocol and reloads so the connection is usable.
        private func loadOrCreateManager() async throws -> NETunnelProviderManager {
            logger.notice("ios tunnel loading managers from preferences")
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let existing = managers.first { candidate in
                let tunnelProtocol = candidate.protocolConfiguration as? NETunnelProviderProtocol
                return tunnelProtocol?.providerBundleIdentifier == providerBundleIdentifier
            }
            let manager = existing ?? NETunnelProviderManager()

            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
            tunnelProtocol.serverAddress = tunnelServerAddress
            manager.protocolConfiguration = tunnelProtocol
            manager.localizedDescription = tunnelLocalizedDescription
            manager.isEnabled = true

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            logger.notice(
                "ios tunnel manager saved reused=\(existing != nil, privacy: .public)"
            )
            return manager
        }

        private func observeStatus(on connection: NEVPNConnection) {
            logger.notice("ios tunnel observing connection status")
            if let statusObserver {
                NotificationCenter.default.removeObserver(statusObserver)
            }
            statusObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: connection,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyCurrentStatus()
                }
            }
        }

        private func applyCurrentStatus() {
            guard let manager else {
                return
            }
            updateStatus(from: manager)
        }

        private func updateStatus(from manager: NETunnelProviderManager) {
            let status = manager.connection.status
            statusDescription = PhoneTunnelManager.describe(status)
            logger.notice(
                "ios tunnel status updated status=\(self.statusDescription, privacy: .public)"
            )
        }

        private static func describe(_ status: NEVPNStatus) -> String {
            switch status {
            case .connected:
                return "Connected"
            case .connecting:
                return "Connecting"
            case .disconnected:
                return "Disconnected"
            case .disconnecting:
                return "Disconnecting"
            case .invalid:
                return "Invalid"
            case .reasserting:
                return "Reasserting"
            @unknown default:
                return "Unknown"
            }
        }
    }
#endif

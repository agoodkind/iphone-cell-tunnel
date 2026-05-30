import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension
import Observation
import UIKit

private let logger = CellTunnelLog.logger(category: .relay)

private let tunnelProviderBundleSuffix = ".Tunnel"
private let tunnelServerAddress = "Cell Tunnel"
private let tunnelLocalizedDescription = "Cell Tunnel"
private let relayStoppedStateDescription = "Stopped"

/// Drives the iOS background tunnel: it loads or creates the single
/// `NETunnelProviderManager` that points at the embedded relay extension,
/// enables on-demand so the system keeps the tunnel up, starts the session when
/// it is not already connected, and then polls the extension for status over the
/// provider message channel. The relay data plane lives entirely in the
/// extension now, so this type owns no forwarder, control listener, or path
/// monitor; it only reflects the polled snapshot into `@Observable` state for
/// the views.
@MainActor
@Observable
final class PhoneRelayController: @unchecked Sendable {
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    var throughputTask: Task<Void, Never>?
    var throughputBaseline = TunnelCounters()
    var hasSeededBaseline = false

    var isRunning = false
    var connectedPeerName: String?
    var cellularPath = CellularPathSnapshot()
    var counters = TunnelCounters()
    var uploadMbps: Double = 0
    var downloadMbps: Double = 0
    var lastError: String?
    var relayStateDescription = relayStoppedStateDescription

    // The provider bundle id nests under the host app: the app's own bundle id
    // with a ".Tunnel" suffix matches PHONE_PROVIDER_BUNDLE_ID.
    private var providerBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "") + tunnelProviderBundleSuffix
    }

    func start() async {
        logger.notice("phone relay controller start requested")
        publishDeviceNameForRelayAdvertisement()
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            let loadedManager = try await loadOrCreateManager()
            manager = loadedManager
            observeStatus(on: loadedManager.connection)
            try startSessionIfNeeded(on: loadedManager)
            applyConnectionStatus(loadedManager.connection.status)
            startThroughputLoop()
            logger.notice("phone relay controller start completed")
        } catch {
            let message = String(describing: error)
            lastError = message
            logger.error(
                """
                phone relay controller start failed \
                details=\(message, privacy: .public) recovery=surface-to-ui
                """
            )
        }
    }

    func stop() async {
        logger.notice("phone relay controller stop requested")
        guard let manager else {
            logger.notice("phone relay controller stop ignored because no manager is loaded")
            return
        }
        stopThroughputLoop()
        // On-demand keeps reconnecting the tunnel, so disable the rules and
        // persist before stopping; start re-enables them via loadOrCreateManager.
        manager.isOnDemandEnabled = false
        do {
            try await manager.saveToPreferences()
        } catch {
            logger.error(
                """
                phone relay controller failed disabling on-demand before stop \
                details=\(String(describing: error), privacy: .public) recovery=continue-stop
                """
            )
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            logger.notice("phone relay controller stop ignored because session is unavailable")
            return
        }
        session.stopTunnel()
        applyConnectionStatus(session.status)
    }

    // The background extension has no UIKit and otherwise advertises the process
    // host name, so the app publishes the user-visible device name into the
    // shared app group for the provider to use as the Bonjour service name.
    private func publishDeviceNameForRelayAdvertisement() {
        let defaults = UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
        storeRelayServiceDeviceName(UIDevice.current.name, defaults: defaults)
        logger.notice("phone relay controller published device name for relay advertisement")
    }

    func suspendPolling() {
        logger.notice("phone relay controller suspending status poll")
        stopThroughputLoop()
    }

    func resumePolling() {
        logger.notice("phone relay controller resuming status poll")
        guard let manager else {
            return
        }
        applyConnectionStatus(manager.connection.status)
        startThroughputLoop()
    }

    // Reuses the first manager that already targets this provider bundle id,
    // otherwise builds a fresh one. Either way it persists an enabled
    // NETunnelProviderProtocol with on-demand rules so the system keeps the
    // tunnel connected, then reloads so the connection is usable.
    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        logger.notice("phone relay controller loading managers from preferences")
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
        manager.isOnDemandEnabled = true
        let connectRule = NEOnDemandRuleConnect()
        connectRule.interfaceTypeMatch = .any
        manager.onDemandRules = [connectRule]

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        logger.notice(
            "phone relay controller manager saved reused=\(existing != nil, privacy: .public)"
        )
        return manager
    }

    // Mirrors the macOS AgentTunnelController isSessionActive gate so a tunnel
    // the system already brought up via on-demand is not torn down and
    // restarted on app launch.
    private func startSessionIfNeeded(on manager: NETunnelProviderManager) throws {
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw PhoneRelayControllerError.sessionUnavailable
        }
        guard !isSessionActive(status: session.status) else {
            logger.notice("phone relay controller session already active; skipping start")
            return
        }
        try session.startTunnel(options: nil)
        logger.notice("phone relay controller startTunnel issued")
    }

    private func isSessionActive(status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    private func observeStatus(on connection: NEVPNConnection) {
        logger.notice("phone relay controller observing connection status")
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyConnectionStatus(connection.status)
            }
        }
    }

    func applyConnectionStatus(_ status: NEVPNStatus) {
        isRunning = isSessionActive(status: status)
        if status == .invalid {
            lastError = "vpn configuration not approved"
        }
        logger.notice(
            "phone relay controller connection status=\(self.statusDescription(status), privacy: .public)"
        )
    }

    private func statusDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            return "invalid"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reasserting:
            return "reasserting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown"
        }
    }

    var session: NETunnelProviderSession? {
        manager?.connection as? NETunnelProviderSession
    }
}

enum PhoneRelayControllerError: LocalizedError {
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "tunnel provider session is unavailable"
        }
    }
}

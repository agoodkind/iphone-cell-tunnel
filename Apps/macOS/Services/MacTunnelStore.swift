import CellTunnelCore
import CellTunnelLog
import Foundation
import Observation

private let logger = CellTunnelLog.logger(category: .store)

enum MacTunnelSection: Hashable {
    case tunnel
    case cellular
    case daemon
}

enum MacTunnelRunState: String, Sendable {
    case error
    case running
    case stopped

    var displayName: String {
        switch self {
        case .error:
            return "Error"
        case .running:
            return "Running"
        case .stopped:
            return "Stopped"
        }
    }
}

enum MacTunnelRouteState: String, Sendable {
    case installed
    case notInstalled

    var displayName: String {
        switch self {
        case .installed:
            return "Installed"
        case .notInstalled:
            return "Not installed"
        }
    }
}

enum MacRelayDiscoveryState: Sendable {
    case error
    case resolved(Int)
    case searching
    case selected(String)
    case stopped

    var displayName: String {
        switch self {
        case .error:
            return "Error"
        case .resolved(let serviceCount):
            return "Resolved \(serviceCount)"
        case .searching:
            return "Searching"
        case .selected(let serviceName):
            return "Selected \(serviceName)"
        case .stopped:
            return "Stopped"
        }
    }
}

struct MacTunnelDaemonStatus: Sendable {
    let tunnelState: MacTunnelRunState
    let routeState: MacTunnelRouteState

    static func parse(status: TunnelDaemonStatusSnapshot) -> Self {
        logger.notice(
            "parsing mac tunnel daemon status running=\(status.running, privacy: .public)")
        let tunnelState: MacTunnelRunState
        if status.running {
            tunnelState = .running
        } else {
            tunnelState = .stopped
        }
        let routeState: MacTunnelRouteState =
            status.routeState == .installed ? .installed : .notInstalled
        return Self(tunnelState: tunnelState, routeState: routeState)
    }
}

private enum MacTunnelSettingsKeys {
    static let wireGuardConfigPath = "wireGuardConfigPath"
}

@MainActor
@Observable
final class MacTunnelStore {
    var selection: MacTunnelSection? = .tunnel
    var tunnelState = MacTunnelRunState.stopped
    var helperState = TunnelHelperState.notRegistered
    var peerName = "Not selected"
    var routeState = MacTunnelRouteState.notInstalled
    var counters = TunnelCounters()
    var daemonOutput = ""
    var lastDaemonError: String?
    var wireGuardConfigPath: String {
        didSet {
            persistSettings()
        }
    }
    var relayDiscoveryState = MacRelayDiscoveryState.stopped
    var discoveredRelayServices: [TunnelRelayService] = []
    var selectedRelayServiceID: TunnelRelayService.ID?

    private let daemonClient: any TunnelControlClientProtocol
    private let helperService: TunnelHelperService
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        daemonClient: any TunnelControlClientProtocol = TunnelControlClient(),
        helperService: TunnelHelperService = TunnelHelperService()
    ) {
        self.defaults = defaults
        self.daemonClient = daemonClient
        self.helperService = helperService
        wireGuardConfigPath =
            defaults.string(forKey: MacTunnelSettingsKeys.wireGuardConfigPath) ?? ""
        logger.notice(
            "mac tunnel settings loaded wireguardConfigConfigured=\(!self.wireGuardConfigPath.isEmpty, privacy: .public)"
        )
    }

    func start() {
        logger.notice("mac tunnel start requested")
        Task { [weak self] in
            guard let self else {
                return
            }
            await executeStatusOperation("start") {
                do {
                    return .success(
                        try await daemonClient.startTunnel(
                            settings: TunnelStartSettings(wireGuardConfigPath: wireGuardConfigPath)
                        )
                    )
                } catch {
                    logger.error(
                        "mac tunnel start request failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    return .failure(error)
                }
            }
        }
    }

    func stop() {
        logger.notice("mac tunnel stop requested")
        Task { [weak self] in
            guard let self else {
                return
            }
            await executeStatusOperation("stop") {
                do {
                    return .success(try await daemonClient.stopTunnel())
                } catch {
                    logger.error(
                        "mac tunnel stop request failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    return .failure(error)
                }
            }
        }
    }

    func refreshStatus() {
        logger.notice("mac tunnel status refresh requested")
        refreshHelperStatus()
        Task { [weak self] in
            guard let self else {
                return
            }
            await executeStatusOperation("status") {
                do {
                    return .success(try await daemonClient.status())
                } catch {
                    logger.error(
                        "mac tunnel status request failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    return .failure(error)
                }
            }
        }
    }

    func refreshHelperStatus() {
        logger.notice("mac helper status refresh requested")
        let status = helperService.status()
        helperState = status.state
        logger.notice("mac helper status applied state=\(status.state.rawValue, privacy: .public)")
    }

    func installHelper() {
        logger.notice("mac helper install requested")
        do {
            try helperService.register()
            refreshHelperStatus()
        } catch {
            daemonOutput = error.localizedDescription
            logger.error(
                "mac helper install failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func uninstallHelper() {
        logger.notice("mac helper uninstall requested")
        do {
            try helperService.unregister()
            refreshHelperStatus()
        } catch {
            daemonOutput = error.localizedDescription
            logger.error(
                "mac helper uninstall failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func openHelperSettings() {
        logger.notice("mac helper settings requested")
        helperService.openSystemSettings()
    }

    func selectWireGuardConfigFile(_ url: URL) {
        wireGuardConfigPath = url.path
        logger.notice(
            "wireguard config file selected pathConfigured=\(!url.path.isEmpty, privacy: .public)")
    }

    func startRelayDiscovery() {
        relayDiscoveryState = .searching
        logger.notice("relay discovery requested")
        Task { [weak self] in
            guard let self else {
                return
            }
            await executeDiscoveryOperation("start-discovery") {
                do {
                    return .success(try await daemonClient.startRelayDiscovery())
                } catch {
                    logger.error(
                        "relay discovery start request failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    return .failure(error)
                }
            }
        }
    }

    func stopRelayDiscovery() {
        relayDiscoveryState = .stopped
        logger.notice("relay discovery stop requested")
        Task { [weak self] in
            guard let self else {
                return
            }
            await executeDiscoveryOperation("stop-discovery") {
                do {
                    return .success(try await daemonClient.stopRelayDiscovery())
                } catch {
                    logger.error(
                        "relay discovery stop request failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    return .failure(error)
                }
            }
        }
    }

    func selectRelayService(_ service: TunnelRelayService) {
        logger.notice("relay service selection requested serviceID=\(service.id, privacy: .public)")
        Task { [weak self] in
            guard let self else {
                return
            }
            await executeDiscoveryOperation("select-relay") {
                do {
                    return .success(
                        try await daemonClient.selectRelayService(serviceID: service.id))
                } catch {
                    logger.error(
                        "relay selection request failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    return .failure(error)
                }
            }
        }
    }

    private func executeStatusOperation(
        _ command: String,
        operation: @MainActor () async -> Result<TunnelDaemonStatusSnapshot, Error>
    ) async {
        switch await operation() {
        case .success(let status):
            apply(status: status)
            daemonOutput = status.renderedOutput
            logger.notice("mac tunnel daemon command applied command=\(command, privacy: .public)")
        case .failure(let error):
            daemonOutput = error.localizedDescription
            lastDaemonError = error.localizedDescription
            tunnelState = .error
            logger.error(
                """
                mac tunnel daemon command failed command=\(command, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    private func executeDiscoveryOperation(
        _ command: String,
        operation: @MainActor () async -> Result<TunnelDiscoverySnapshot, Error>
    ) async {
        switch await operation() {
        case .success(let snapshot):
            apply(discovery: snapshot)
            daemonOutput = snapshot.renderedOutput
            logger.notice("relay discovery command applied command=\(command, privacy: .public)")
        case .failure(let error):
            relayDiscoveryState = .error
            daemonOutput = error.localizedDescription
            lastDaemonError = error.localizedDescription
            logger.error(
                """
                relay discovery command failed command=\(command, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    private func apply(status: TunnelDaemonStatusSnapshot) {
        logger.notice("applying tunnel daemon status to mac store")
        let parsedStatus = MacTunnelDaemonStatus.parse(status: status)
        tunnelState = parsedStatus.tunnelState
        routeState = parsedStatus.routeState
        lastDaemonError = status.lastError
        apply(discovery: status.discovery)
        if let activeRelayEndpoint = status.activeRelayEndpoint {
            peerName = activeRelayEndpoint.socketAddress
        } else if let selectedEndpoint = status.discovery.selectedEndpoint {
            peerName = selectedEndpoint.socketAddress
        } else {
            peerName = peerDisplayName(for: status.peerState)
        }
    }

    private func apply(discovery snapshot: TunnelDiscoverySnapshot) {
        discoveredRelayServices = snapshot.services
        selectedRelayServiceID = snapshot.selectedServiceID
        lastDaemonError = snapshot.lastError ?? lastDaemonError
        relayDiscoveryState = relayDiscoveryState(for: snapshot)
    }

    private func relayDiscoveryState(
        for snapshot: TunnelDiscoverySnapshot
    ) -> MacRelayDiscoveryState {
        if let selectedRelayService = snapshot.services.first(where: { service in
            service.id == snapshot.selectedServiceID
        }) {
            return .selected(selectedRelayService.serviceName)
        }
        switch snapshot.phase {
        case .browsing:
            return .searching
        case .failed:
            return .error
        case .ready:
            return .resolved(snapshot.services.count)
        case .stopped:
            return .stopped
        }
    }

    private func persistSettings() {
        defaults.set(wireGuardConfigPath, forKey: MacTunnelSettingsKeys.wireGuardConfigPath)
        logger.debug(
            "mac tunnel settings persisted wireguardConfigConfigured=\(!self.wireGuardConfigPath.isEmpty, privacy: .public)"
        )
    }

    private func peerDisplayName(for state: TunnelPeerState) -> String {
        switch state {
        case .notSelected:
            return "Not selected"
        case .relaySelected:
            return "Relay selected"
        case .wireGuardConfigured:
            return "WireGuard configured"
        }
    }
}

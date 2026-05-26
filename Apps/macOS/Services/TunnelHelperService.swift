import CellTunnelLog
import Foundation
import ServiceManagement

private let logger = CellTunnelLog.logger(category: .daemon)

enum TunnelHelperState: String, Sendable {
    case enabled
    case notFound
    case notRegistered
    case requiresApproval
    case unknown

    var displayName: String {
        switch self {
        case .enabled:
            return "Enabled"
        case .notFound:
            return "Not found"
        case .notRegistered:
            return "Not registered"
        case .requiresApproval:
            return "Requires approval"
        case .unknown:
            return "Unknown"
        }
    }
}

struct TunnelHelperStatus: Sendable {
    let helperState: TunnelHelperState
    let daemonState: TunnelHelperState

    var state: TunnelHelperState {
        combinedState(helperState: helperState, daemonState: daemonState)
    }
}

struct TunnelHelperService {
    private let helperPlistName = "io.goodkind.celltunneldhelperd.plist"
    private let daemonPlistName = "io.goodkind.celltunneld.plist"

    func status() -> TunnelHelperStatus {
        let helperState = mapState(SMAppService.daemon(plistName: helperPlistName).status)
        let daemonState = mapState(SMAppService.agent(plistName: daemonPlistName).status)
        logger.notice(
            """
            install status resolved helper=\(helperState.rawValue, privacy: .public) \
            daemon=\(daemonState.rawValue, privacy: .public)
            """
        )
        return TunnelHelperStatus(helperState: helperState, daemonState: daemonState)
    }

    func register() throws {
        let helperService = SMAppService.daemon(plistName: helperPlistName)
        if helperService.status != .enabled {
            logger.notice("privileged helper registration requested")
            try helperService.register()
            logger.notice("privileged helper registration completed")
        }
        let daemonService = SMAppService.agent(plistName: daemonPlistName)
        if daemonService.status != .enabled {
            logger.notice("user daemon registration requested")
            try daemonService.register()
            logger.notice("user daemon registration completed")
        }
    }

    func unregister() throws {
        var thrown: Error?
        do {
            logger.notice("user daemon unregistration requested")
            try SMAppService.agent(plistName: daemonPlistName).unregister()
        } catch {
            logger.error(
                "user daemon unregistration failed error=\(error.localizedDescription, privacy: .public)"
            )
            thrown = error
        }
        do {
            logger.notice("privileged helper unregistration requested")
            try SMAppService.daemon(plistName: helperPlistName).unregister()
        } catch {
            logger.error(
                "privileged helper unregistration failed error=\(error.localizedDescription, privacy: .public)"
            )
            if thrown == nil {
                thrown = error
            }
        }
        if let thrown {
            throw thrown
        }
    }

    func openSystemSettings() {
        logger.notice("opening system settings for install approval")
        SMAppService.openSystemSettingsLoginItems()
    }

    private func mapState(_ status: SMAppService.Status) -> TunnelHelperState {
        switch status {
        case .enabled:
            return .enabled
        case .notFound:
            return .notFound
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        @unknown default:
            return .unknown
        }
    }
}

private func combinedState(
    helperState: TunnelHelperState,
    daemonState: TunnelHelperState
) -> TunnelHelperState {
    if helperState == .requiresApproval || daemonState == .requiresApproval {
        return .requiresApproval
    }
    if helperState == .enabled, daemonState == .enabled {
        return .enabled
    }
    for state in [helperState, daemonState] {
        switch state {
        case .notRegistered, .notFound, .unknown:
            return state
        case .enabled, .requiresApproval:
            continue
        }
    }
    return .unknown
}

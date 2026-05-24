import CellTunnelLog
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
    let state: TunnelHelperState
}

struct TunnelHelperService {
    private let plistName = "io.goodkind.celltunneld.plist"

    func status() -> TunnelHelperStatus {
        let service = SMAppService.daemon(plistName: plistName)
        let state: TunnelHelperState
        switch service.status {
        case .enabled:
            state = .enabled
        case .notFound:
            state = .notFound
        case .notRegistered:
            state = .notRegistered
        case .requiresApproval:
            state = .requiresApproval
        @unknown default:
            state = .unknown
        }

        logger.notice("helper status resolved state=\(state.rawValue, privacy: .public)")
        return TunnelHelperStatus(state: state)
    }

    func register() throws {
        logger.notice("helper registration requested plist=\(plistName, privacy: .public)")
        try SMAppService.daemon(plistName: plistName).register()
        logger.notice("helper registration completed plist=\(plistName, privacy: .public)")
    }

    func unregister() throws {
        logger.notice("helper unregistration requested plist=\(plistName, privacy: .public)")
        try SMAppService.daemon(plistName: plistName).unregister()
        logger.notice("helper unregistration completed plist=\(plistName, privacy: .public)")
    }

    func openSystemSettings() {
        logger.notice("opening system settings for helper approval")
        SMAppService.openSystemSettingsLoginItems()
    }
}

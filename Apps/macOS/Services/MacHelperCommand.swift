import CellTunnelLog
import Foundation

private let helperCommandArgument = "--cell-tunnel-install-helper"
private let helperCommandTimeout: TimeInterval = 60
private let helperCommandPollInterval: TimeInterval = 0.5
private let helperCommandLogger = CellTunnelLog.logger(category: .app)

enum MacHelperCommand {
    static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.contains(helperCommandArgument) else {
            return false
        }

        do {
            try installHelperAndWait()
            return true
        } catch {
            helperCommandLogger.error(
                "headless helper install failed error=\(error.localizedDescription, privacy: .public)"
            )
            writeStandardError("helper install failed: \(error.localizedDescription)\n")
            return true
        }
    }

    private static func installHelperAndWait() throws {
        helperCommandLogger.notice("headless install requested")
        let helperService = TunnelHelperService()
        let initialStatus = helperService.status()
        if initialStatus.state == .enabled {
            helperCommandLogger.notice("headless install found both pieces enabled")
            return
        }

        do {
            try helperService.register()
        } catch {
            let recoveryStatus = helperService.status()
            if recoveryStatus.state == .enabled {
                helperCommandLogger.notice("headless install recovered after register error")
                return
            }
            guard recoveryStatus.state == .requiresApproval else {
                throw error
            }
            helperService.openSystemSettings()
        }

        let deadline = Date().addingTimeInterval(helperCommandTimeout)
        while Date() < deadline {
            let state = helperService.status().state
            if state == .enabled {
                helperCommandLogger.notice("headless install enabled both pieces")
                return
            }
            if state == .requiresApproval {
                helperService.openSystemSettings()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(helperCommandPollInterval))
        }

        throw HelperCommandError.timedOut
    }

    private static func writeStandardError(_ message: String) {
        guard let data = message.data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }
}

enum HelperCommandError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "helper registration timed out"
        }
    }
}

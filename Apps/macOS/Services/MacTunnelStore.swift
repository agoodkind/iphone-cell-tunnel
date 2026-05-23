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

struct MacTunnelDaemonStatus: Sendable {
    let tunnelState: MacTunnelRunState
    let routeState: MacTunnelRouteState

    static func parse(output: String) -> Self {
        Self(
            tunnelState: output.contains("running=true") ? .running : .stopped,
            routeState: output.contains("routes=installed") ? .installed : .notInstalled
        )
    }
}

@Observable
final class MacTunnelStore {
    var selection: MacTunnelSection? = .tunnel
    var tunnelState = MacTunnelRunState.stopped
    var peerName = "Not paired"
    var routeState = MacTunnelRouteState.notInstalled
    var counters = TunnelCounters()
    var daemonOutput = ""

    private let daemonClient = TunnelDaemonClient()

    var counterDescription: String {
        "tcp=\(counters.tcpFlows) udp=\(counters.udpFlows) icmp=\(counters.icmpFlows)"
    }

    var tunnelStateDescription: String {
        tunnelState.displayName
    }

    var routeStateDescription: String {
        routeState.displayName
    }

    func start() {
        logger.notice("mac tunnel start requested")
        runDaemon(command: .startDryRun)
    }

    func stop() {
        logger.notice("mac tunnel stop requested")
        runDaemon(command: .stopDryRun)
    }

    func refreshStatus() {
        logger.notice("mac tunnel status refresh requested")
        runDaemon(command: .status)
    }

    private func runDaemon(command: TunnelDaemonCommand) {
        do {
            let result = try daemonClient.run(command: command)
            let parsedStatus = MacTunnelDaemonStatus.parse(output: result.text)
            daemonOutput = result.text
            tunnelState = parsedStatus.tunnelState
            routeState = parsedStatus.routeState
            logger.notice(
                """
                mac tunnel daemon command applied command=\(command.logName, privacy: .public) \
                tunnel=\(parsedStatus.tunnelState.rawValue, privacy: .public) \
                route=\(parsedStatus.routeState.rawValue, privacy: .public)
                """
            )
        } catch {
            daemonOutput = error.localizedDescription
            tunnelState = .error
            logger.error(
                """
                mac tunnel daemon command failed command=\(command.logName, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

enum DaemonControlRPC: String, Codable, Sendable {
    case status
    case check
    case startTunnel = "start-tunnel"
    case stopTunnel = "stop-tunnel"
    case startRelayDiscovery = "start-relay-discovery"
    case stopRelayDiscovery = "stop-relay-discovery"
    case listRelayServices = "list-relay-services"
    case selectRelayService = "select-relay-service"
}

struct DaemonControlRequest: Codable, Sendable {
    var version: Int = 1
    var rpc: DaemonControlRPC
    var startSettings: TunnelStartSettings?
    var serviceID: String?
}

struct DaemonControlResponse: Codable, Sendable {
    var version: Int = 1
    var status: TunnelDaemonStatusSnapshot?
    var report: TunnelEnvironmentReport?
    var discovery: TunnelDiscoverySnapshot?
    var failure: DaemonControlResponseFailure?
}

struct DaemonControlResponseFailure: Codable, Sendable {
    var errorCode: TunnelControlErrorCode
    var message: String
}

struct TunnelComponents {
    let device: UtunDevice
    let transport: RelayTransport
    let runtime: WireGuardRuntime
    let routes: RouteManager
    let parsedConfig: WireGuardClientConfig
    let relayEndpoint: TunnelRelayEndpoint
    let plan: RoutePlan
}

actor DaemonState {
    var status = TunnelDaemonStatusSnapshot()
    var discovery = TunnelDiscoverySnapshot()
    var wireGuardRuntime: WireGuardRuntime?
    var relayTransport: RelayTransport?
    var discoveryManager: DiscoveryManager?
    var utunDevice: UtunDevice?
    var routeManager: RouteManager?

    func currentStatus() -> TunnelDaemonStatusSnapshot {
        var snapshot = status
        snapshot.discovery = discovery
        return snapshot
    }

    func performCheck() -> TunnelEnvironmentReport {
        let pairs: [(String, String)] = [
            ("daemon_version", "phase1"),
            ("wireguard_runtime_active", "\(wireGuardRuntime != nil)"),
            ("utun_open", "\(utunDevice?.interfaceName ?? "")"),
        ]
        let payload: [[String: String]] = pairs.map { ["name": $0.0, "value": $0.1] }
        let report: TunnelEnvironmentReport
        do {
            let data = try JSONSerialization.data(withJSONObject: ["checks": payload])
            report = try JSONDecoder().decode(TunnelEnvironmentReport.self, from: data)
        } catch {
            logger.error(
                "environment report encode failed error=\(String(describing: error), privacy: .public)"
            )
            report = TunnelEnvironmentReport()
        }
        return report
    }

    func startDiscovery() async -> TunnelDiscoverySnapshot {
        if discoveryManager == nil {
            let manager = DiscoveryManager()
            await manager.start()
            discoveryManager = manager
        }
        discovery.phase = .browsing
        logger.notice("relay discovery requested")
        return discovery
    }

    func stopDiscovery() async -> TunnelDiscoverySnapshot {
        if let manager = discoveryManager {
            await manager.stop()
        }
        discoveryManager = nil
        discovery.phase = .stopped
        discovery.services = []
        logger.notice("relay discovery stopped")
        return discovery
    }

    func listDiscovery() -> TunnelDiscoverySnapshot {
        discovery
    }

    func selectRelay(serviceID: String) -> TunnelDiscoverySnapshot {
        discovery.selectedServiceID = serviceID
        for index in discovery.services.indices {
            discovery.services[index].isSelected = discovery.services[index].id == serviceID
        }
        logger.notice("relay service selected id=\(serviceID, privacy: .public)")
        return discovery
    }

    func shutdown() async {
        _ = await stopTunnel()
        _ = await stopDiscovery()
        logger.notice("daemon state shutdown complete")
    }

    func daemonError(code: TunnelControlErrorCode, message: String) -> TunnelDaemonError {
        TunnelDaemonError.controlFailure(
            TunnelControlFailure(errorCode: code, message: message)
        )
    }
}

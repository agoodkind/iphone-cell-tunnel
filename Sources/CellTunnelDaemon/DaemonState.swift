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

struct OpenedUtun {
    let fileDescriptor: Int32
    let interfaceName: String
}

struct TunnelComponents {
    let device: OpenedUtun
    let transport: RelayTransport
    let bindBridge: LoopbackBindBridge
    let runtime: WireGuardRuntime
    let controlChannel: ControlChannel
    let parsedConfig: WireGuardClientConfig
    let relayEndpoint: TunnelRelayEndpoint
    let plan: RoutePlan
}

actor DaemonState {
    var status = TunnelDaemonStatusSnapshot()
    var discovery = TunnelDiscoverySnapshot()
    var wireGuardRuntime: WireGuardRuntime?
    var relayTransport: RelayTransport?
    var loopbackBridge: LoopbackBindBridge?
    var discoveryManager: DiscoveryManager?
    var utunDevice: OpenedUtun?
    var routesInstalled = false
    var controlChannel: ControlChannel?
    let helperClient = HelperClient()

    func currentStatus() -> TunnelDaemonStatusSnapshot {
        var snapshot = status
        snapshot.discovery = discovery
        return snapshot
    }

    func performCheck() -> TunnelEnvironmentReport {
        let pairs: [(String, String)] = [
            ("daemon_version", "phase1"),
            ("wireguard_runtime_active", "\(wireGuardRuntime != nil)"),
            ("utun_open", utunDevice?.interfaceName ?? ""),
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
            await manager.start { [weak self] services in
                guard self != nil else {
                    return
                }
                Task { [weak self] in
                    await self?.applyDiscoveredServices(services)
                }
            }
            discoveryManager = manager
        }
        discovery.phase = .browsing
        discovery.lastError = nil
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
        discovery.selectedEndpoint = nil
        logger.notice("relay discovery stopped")
        return discovery
    }

    func listDiscovery() -> TunnelDiscoverySnapshot {
        discovery
    }

    func selectRelay(serviceID: String) async -> TunnelDiscoverySnapshot {
        discovery.selectedServiceID = serviceID
        discovery.selectedEndpoint = nil
        discovery.lastError = nil
        for index in discovery.services.indices {
            discovery.services[index].isSelected = discovery.services[index].id == serviceID
        }
        logger.notice("relay service selected id=\(serviceID, privacy: .public)")

        guard let manager = discoveryManager else {
            discovery.lastError = "discovery not running"
            return discovery
        }

        do {
            let resolved = try await manager.resolve(serviceID)
            discovery.selectedEndpoint = resolved
            discovery.phase = .ready
            if let preferred = resolved.host as String?, !preferred.isEmpty {
                logger.notice(
                    """
                    relay service resolved id=\(serviceID, privacy: .public) \
                    endpoint=\(resolved.socketAddress, privacy: .public)
                    """
                )
            }
            applyResolvedEndpoint(resolved, to: serviceID)
        } catch {
            let description = String(describing: error)
            discovery.lastError = description
            discovery.phase = .failed
            logger.error(
                """
                relay service resolve failed id=\(serviceID, privacy: .public) \
                error=\(description, privacy: .public)
                """
            )
        }
        return discovery
    }

    private func applyDiscoveredServices(_ services: Set<DiscoveredService>) {
        var mapped: [TunnelRelayService] = []
        mapped.reserveCapacity(services.count)
        for service in services {
            let resolved = service.resolvedEndpoint
            let endpoints: [TunnelRelayEndpoint]
            if let resolved {
                endpoints = [resolved]
            } else {
                endpoints = []
            }
            mapped.append(
                TunnelRelayService(
                    id: service.identifier,
                    serviceName: service.serviceName,
                    serviceType: service.serviceType,
                    domain: service.domain,
                    interfaceIndex: service.interfaceIndex,
                    hostName: service.serviceName,
                    endpoints: endpoints,
                    preferredEndpoint: resolved,
                    isSelected: service.identifier == discovery.selectedServiceID
                )
            )
        }
        mapped.sort { $0.serviceName < $1.serviceName }
        discovery.services = mapped
        if !mapped.isEmpty, discovery.phase == .browsing {
            discovery.phase = .ready
        }
        guard let selectedID = discovery.selectedServiceID else {
            return
        }
        guard let match = mapped.first(where: { $0.id == selectedID }) else {
            return
        }
        if let resolved = match.preferredEndpoint {
            discovery.selectedEndpoint = resolved
        }
    }

    private func applyResolvedEndpoint(_ endpoint: TunnelRelayEndpoint, to serviceID: String) {
        for index in discovery.services.indices where discovery.services[index].id == serviceID {
            discovery.services[index].preferredEndpoint = endpoint
            if !discovery.services[index].endpoints.contains(endpoint) {
                discovery.services[index].endpoints.append(endpoint)
            }
        }
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

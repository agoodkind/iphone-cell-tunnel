import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)
private let discoverPollingInterval = Duration.milliseconds(250)
private let discoverTimeout = Duration.seconds(10)

public enum TunnelControlCLIAction: Equatable, Sendable {
    case check
    case discover
    case probe
    case start(TunnelStartSettings)
    case startDiscovery
    case status
    case stop
    case stopDiscovery

    public static func parse(arguments: [String]) throws -> Self {
        logger.notice(
            "parsing tunnel control cli action argumentCount=\(arguments.count, privacy: .public)")
        guard let command = arguments.first else {
            throw TunnelDaemonError.usage("missing command")
        }

        switch command {
        case "status":
            return .status
        case "check":
            return .check
        case "start-discovery":
            return .startDiscovery
        case "stop-discovery":
            return .stopDiscovery
        case "discover":
            return .discover
        case "probe":
            return .probe
        case "stop":
            return .stop
        case "start":
            return .start(try parseStart(arguments: Array(arguments.dropFirst())))
        default:
            throw TunnelDaemonError.usage("unknown command: \(command)")
        }
    }

    private static func parseStart(arguments: [String]) throws -> TunnelStartSettings {
        var configPath = ""
        var relayEndpoint: TunnelRelayEndpoint?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--config":
                guard index + 1 < arguments.count else {
                    throw TunnelDaemonError.usage("missing value for --config")
                }
                configPath = arguments[index + 1]
                index += 2
            case "--relay":
                guard index + 1 < arguments.count else {
                    throw TunnelDaemonError.usage("missing value for --relay")
                }
                relayEndpoint = try TunnelRelayEndpoint.parse(argument: arguments[index + 1])
                index += 2
            default:
                throw TunnelDaemonError.usage("unknown start option: \(argument)")
            }
        }

        guard !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TunnelDaemonError.usage("start requires --config <path>")
        }
        return TunnelStartSettings(wireGuardConfigPath: configPath, relayEndpoint: relayEndpoint)
    }
}

public struct TunnelControlCLIExecutor: Sendable {
    private let client: any TunnelControlClientProtocol

    public init(client: any TunnelControlClientProtocol) {
        self.client = client
    }

    public func run(action: TunnelControlCLIAction) async throws -> String {
        logger.notice("executing tunnel control cli action")
        switch action {
        case .status:
            let status = try await client.status()
            return status.renderedOutput
        case .check:
            let report = try await client.check()
            return report.renderedOutput
        case .startDiscovery:
            let snapshot = try await client.startRelayDiscovery()
            return snapshot.renderedOutput
        case .stopDiscovery:
            let snapshot = try await client.stopRelayDiscovery()
            return snapshot.renderedOutput
        case .discover:
            return try await discover()
        case .probe:
            return try await probe()
        case .start(let settings):
            let status = try await client.startTunnel(settings: settings)
            return status.renderedOutput
        case .stop:
            let status = try await client.stopTunnel()
            return status.renderedOutput
        }
    }

    private func discover() async throws -> String {
        _ = try await client.startRelayDiscovery()

        let deadline = ContinuousClock.now + discoverTimeout
        while ContinuousClock.now < deadline {
            let snapshot = try await client.listRelayServices()
            let readyServices = snapshot.services.filter { $0.preferredEndpoint != nil }
            if snapshot.selectedEndpoint != nil {
                return snapshot.renderedOutput
            }
            if readyServices.count == 1 {
                let selected = try await client.selectRelayService(serviceID: readyServices[0].id)
                return selected.renderedOutput
            }
            try await Task.sleep(for: discoverPollingInterval)
        }

        let finalSnapshot = try await client.listRelayServices()
        if finalSnapshot.selectedEndpoint != nil {
            return finalSnapshot.renderedOutput
        }

        throw TunnelDaemonError.controlFailure(
            TunnelControlFailure(
                errorCode: .relaySelectionRequired,
                message: "discovery did not resolve exactly one relay service within timeout"
            )
        )
    }

    private func probe() async throws -> String {
        let status = try await client.status()
        let discoveryStart = try await client.startRelayDiscovery()
        let discoveryList = try await client.listRelayServices()

        return [
            "probe=status",
            status.renderedOutput,
            "",
            "probe=start-discovery",
            discoveryStart.renderedOutput,
            "",
            "probe=list-relay-services",
            discoveryList.renderedOutput,
        ].joined(separator: "\n")
    }
}

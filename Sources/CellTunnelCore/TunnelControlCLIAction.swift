import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)
private let deviceListingIndexBase = 1
private let optionArgumentStride = 2
private let noRelayDevicesMessage = "no relay devices found"

public enum TunnelControlCLIAction: Equatable, Sendable {
    case check
    case devices
    case reset
    case select(reference: String)
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
        case "devices":
            return .devices
        case "start-discovery":
            return .startDiscovery
        case "stop-discovery":
            return .stopDiscovery
        case "select":
            return try .select(reference: parseSelect(arguments: Array(arguments.dropFirst())))
        case "stop":
            return .stop
        case "reset":
            return .reset
        case "start":
            return .start(try parseStart(arguments: Array(arguments.dropFirst())))
        default:
            throw TunnelDaemonError.usage("unknown command: \(command)")
        }
    }

    private static func parseSelect(arguments: [String]) throws -> String {
        guard let reference = arguments.first else {
            throw TunnelDaemonError.usage("select requires <n|serviceID>")
        }
        guard arguments.count == 1 else {
            throw TunnelDaemonError.usage("select accepts only <n|serviceID>")
        }
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TunnelDaemonError.usage("select <n|serviceID> must not be empty")
        }
        return trimmed
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
                index += optionArgumentStride
            case "--relay":
                guard index + 1 < arguments.count else {
                    throw TunnelDaemonError.usage("missing value for --relay")
                }
                relayEndpoint = try TunnelRelayEndpoint.parse(argument: arguments[index + 1])
                index += optionArgumentStride
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
        case .devices:
            return try await listDevices()
        case .startDiscovery:
            let snapshot = try await client.startRelayDiscovery()
            return snapshot.renderedOutput
        case .stopDiscovery:
            let snapshot = try await client.stopRelayDiscovery()
            return snapshot.renderedOutput
        case .select(let reference):
            return try await selectDevice(reference: reference)
        case .start(let settings):
            let status = try await client.startTunnel(settings: settings)
            return status.renderedOutput
        case .stop:
            let status = try await client.stopTunnel()
            return status.renderedOutput
        case .reset:
            let status = try await client.reset()
            return status.renderedOutput
        }
    }

    private func listDevices() async throws -> String {
        let snapshot = try await client.listRelayServices()
        return renderDeviceListing(services: snapshot.services)
    }

    private func selectDevice(reference: String) async throws -> String {
        let serviceID = try await resolveServiceID(reference: reference)
        let snapshot = try await client.selectRelayService(serviceID: serviceID)
        return snapshot.renderedOutput
    }

    // A bare integer is a 1-based index into the most recent `devices` listing;
    // anything else is treated as a literal service id.
    private func resolveServiceID(reference: String) async throws -> String {
        guard let index = Int(reference) else {
            return reference
        }
        let snapshot = try await client.listRelayServices()
        let services = snapshot.services
        let offset = index - deviceListingIndexBase
        guard offset >= 0, offset < services.count else {
            throw TunnelDaemonError.usage(
                "select index \(index) is out of range (\(services.count) devices)"
            )
        }
        return services[offset].id
    }

    private func renderDeviceListing(services: [TunnelRelayService]) -> String {
        guard !services.isEmpty else {
            return noRelayDevicesMessage
        }
        var lines: [String] = []
        for (offset, service) in services.enumerated() {
            let position = offset + deviceListingIndexBase
            var line = "\(position)) \(service.serviceName)  \(service.id)"
            if service.isSelected {
                line += " (selected)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

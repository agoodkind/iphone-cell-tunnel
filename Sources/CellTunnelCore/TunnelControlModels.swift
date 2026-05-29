import Foundation

public enum TunnelAddressFamily: String, Codable, Equatable, Sendable {
    case unspecified
    case ipv4
    case ipv6
}

public enum TunnelRouteState: String, Codable, Equatable, Sendable {
    case installed
    case notInstalled = "not-installed"
}

public enum TunnelPeerState: String, Codable, Equatable, Sendable {
    case notSelected = "not-selected"
    case relaySelected = "relay-selected"
    case wireGuardConfigured = "wireguard-configured"
}

public enum TunnelDiscoveryPhase: String, Codable, Equatable, Sendable {
    case browsing
    case failed
    case ready
    case stopped
}

public enum TunnelControlErrorCode: String, Codable, Equatable, Sendable {
    case discoveryUnavailable = "discoveryUnavailable"
    case `internal` = "internal"
    case invalidRelayEndpoint = "invalidRelayEndpoint"
    case missingWireGuardConfigPath = "missingWireGuardConfigPath"
    case relaySelectionRequired = "relaySelectionRequired"
    case relayServiceNotFound = "relayServiceNotFound"
    case runtimeStartFailure = "runtimeStartFailure"
    case unspecified = "unspecified"
}

public let usbmuxdEndpointPrefix = "usbmuxd:"
public let tunneldEndpointPrefix = "tunneld:"

private let prefixedEndpointSchemes = [usbmuxdEndpointPrefix, tunneldEndpointPrefix]

private func prefixedSchemeForHost(_ host: String) -> String? {
    for scheme in prefixedEndpointSchemes where host.hasPrefix(scheme) {
        return scheme
    }
    return nil
}

public struct TunnelRelayEndpoint: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var addressFamily: TunnelAddressFamily

    public init(host: String, port: Int, addressFamily: TunnelAddressFamily = .unspecified) {
        self.host = host
        self.port = port
        self.addressFamily = addressFamily
    }

    public var socketAddress: String {
        if prefixedSchemeForHost(host) != nil {
            return "\(host):\(port)"
        }
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    public var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0
    }

    public static func parse(argument: String) throws -> Self {
        let trimmedArgument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedArgument.isEmpty {
            throw TunnelDaemonError.usage("relay endpoint is empty")
        }

        for scheme in prefixedEndpointSchemes where trimmedArgument.hasPrefix(scheme) {
            let body = String(trimmedArgument.dropFirst(scheme.count))
            guard let lastColonIndex = body.lastIndex(of: ":") else {
                throw TunnelDaemonError.controlFailure(
                    TunnelControlFailure(
                        errorCode: .invalidRelayEndpoint,
                        message: "invalid \(scheme.dropLast()) relay endpoint")
                )
            }
            let udid = String(body[..<lastColonIndex])
            let portString = String(body[body.index(after: lastColonIndex)...])
            guard !udid.isEmpty, let port = Int(portString), port > 0 else {
                throw TunnelDaemonError.controlFailure(
                    TunnelControlFailure(
                        errorCode: .invalidRelayEndpoint,
                        message: "invalid \(scheme.dropLast()) relay endpoint")
                )
            }
            return Self(host: "\(scheme)\(udid)", port: port, addressFamily: .unspecified)
        }

        if trimmedArgument.hasPrefix("[") {
            guard let closingBracketIndex = trimmedArgument.lastIndex(of: "]"),
                let separatorIndex = trimmedArgument[closingBracketIndex...].firstIndex(of: ":")
            else {
                throw TunnelDaemonError.controlFailure(
                    TunnelControlFailure(
                        errorCode: .invalidRelayEndpoint, message: "invalid relay endpoint")
                )
            }
            let host = String(
                trimmedArgument[
                    trimmedArgument.index(after: trimmedArgument.startIndex)..<closingBracketIndex]
            )
            let portString = String(
                trimmedArgument[trimmedArgument.index(after: separatorIndex)...])
            guard let port = Int(portString), port > 0 else {
                throw TunnelDaemonError.controlFailure(
                    TunnelControlFailure(
                        errorCode: .invalidRelayEndpoint, message: "invalid relay endpoint")
                )
            }
            return Self(host: host, port: port, addressFamily: .ipv6)
        }

        let components = trimmedArgument.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2, let port = Int(components[1]), port > 0 else {
            throw TunnelDaemonError.controlFailure(
                TunnelControlFailure(
                    errorCode: .invalidRelayEndpoint, message: "invalid relay endpoint")
            )
        }

        let host = String(components[0])
        let addressFamily: TunnelAddressFamily = host.contains(":") ? .ipv6 : .ipv4
        return Self(host: host, port: port, addressFamily: addressFamily)
    }
}

public struct TunnelRelayService: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var serviceName: String
    public var serviceType: String
    public var domain: String
    public var interfaceIndex: Int
    public var hostName: String
    public var endpoints: [TunnelRelayEndpoint]
    public var preferredEndpoint: TunnelRelayEndpoint?
    public var isSelected: Bool

    public init(
        id: String,
        serviceName: String,
        serviceType: String,
        domain: String,
        interfaceIndex: Int,
        hostName: String,
        endpoints: [TunnelRelayEndpoint],
        preferredEndpoint: TunnelRelayEndpoint?,
        isSelected: Bool
    ) {
        self.id = id
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.domain = domain
        self.interfaceIndex = interfaceIndex
        self.hostName = hostName
        self.endpoints = endpoints
        self.preferredEndpoint = preferredEndpoint
        self.isSelected = isSelected
    }

    public var displayName: String {
        if let preferredEndpoint {
            return "\(serviceName) \(preferredEndpoint.socketAddress)"
        }
        return serviceName
    }
}

public struct TunnelDiscoverySnapshot: Codable, Equatable, Sendable {
    public var phase: TunnelDiscoveryPhase
    public var services: [TunnelRelayService]
    public var selectedServiceID: String?
    public var selectedEndpoint: TunnelRelayEndpoint?
    public var lastError: String?

    public init(
        phase: TunnelDiscoveryPhase = .stopped,
        services: [TunnelRelayService] = [],
        selectedServiceID: String? = nil,
        selectedEndpoint: TunnelRelayEndpoint? = nil,
        lastError: String? = nil
    ) {
        self.phase = phase
        self.services = services
        self.selectedServiceID = selectedServiceID
        self.selectedEndpoint = selectedEndpoint
        self.lastError = lastError
    }

    public var renderedOutput: String {
        var lines = ["discovery=\(phase.rawValue)"]
        if let selectedServiceID, !selectedServiceID.isEmpty {
            lines.append("selected_service_id=\(selectedServiceID)")
        }
        if let selectedEndpoint {
            lines.append("selected_endpoint=\(selectedEndpoint.socketAddress)")
        }
        for service in services {
            lines.append("service=\(service.displayName)")
            lines.append("  id=\(service.id)")
        }
        if let lastError, !lastError.isEmpty {
            lines.append("last_error=\(lastError)")
        }
        return lines.joined(separator: "\n")
    }
}

public struct TunnelStartSettings: Codable, Equatable, Sendable {
    public var wireGuardConfigPath: String
    public var relayEndpoint: TunnelRelayEndpoint?

    public init(wireGuardConfigPath: String = "", relayEndpoint: TunnelRelayEndpoint? = nil) {
        self.wireGuardConfigPath = wireGuardConfigPath
        self.relayEndpoint = relayEndpoint
    }

    public var hasWireGuardConfigPath: Bool {
        !wireGuardConfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasLocalRelayEndpoint: Bool {
        relayEndpoint?.isConfigured == true
    }

    public var usesDaemonSelectedRelay: Bool {
        relayEndpoint == nil
    }

    public var isReadyToStart: Bool {
        hasWireGuardConfigPath
    }
}

public struct TunnelEnvironmentCheckResult: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct TunnelEnvironmentReport: Codable, Equatable, Sendable {
    public var checks: [TunnelEnvironmentCheckResult]

    public init(checks: [TunnelEnvironmentCheckResult] = []) {
        self.checks = checks
    }

    public var renderedOutput: String {
        checks.map { "\($0.name)=\($0.value)" }.joined(separator: "\n")
    }
}

public struct TunnelDaemonStatusSnapshot: Codable, Equatable, Sendable {
    public var running: Bool
    public var routeState: TunnelRouteState
    public var peerState: TunnelPeerState
    public var ipv4Address: String
    public var ipv6Address: String
    public var lastError: String?
    public var discovery: TunnelDiscoverySnapshot
    public var activeRelayEndpoint: TunnelRelayEndpoint?
    public var macCounters: TunnelCounters?
    public var phoneCounters: TunnelCounters?

    public init(
        running: Bool = false,
        routeState: TunnelRouteState = .notInstalled,
        peerState: TunnelPeerState = .notSelected,
        ipv4Address: String = "",
        ipv6Address: String = "",
        lastError: String? = nil,
        discovery: TunnelDiscoverySnapshot = TunnelDiscoverySnapshot(),
        activeRelayEndpoint: TunnelRelayEndpoint? = nil,
        macCounters: TunnelCounters? = nil,
        phoneCounters: TunnelCounters? = nil
    ) {
        self.running = running
        self.routeState = routeState
        self.peerState = peerState
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.lastError = lastError
        self.discovery = discovery
        self.activeRelayEndpoint = activeRelayEndpoint
        self.macCounters = macCounters
        self.phoneCounters = phoneCounters
    }

    public var renderedOutput: String {
        var lines = [
            "running=\(running)",
            "routes=\(routeState.rawValue)",
            "peer=\(peerState.rawValue)",
            "ipv4=\(ipv4Address)",
            "ipv6=\(ipv6Address)",
        ]
        if let activeRelayEndpoint {
            lines.append("relay=\(activeRelayEndpoint.socketAddress)")
        }
        if let macCounters {
            lines.append(contentsOf: renderedCounterLines(macCounters, prefix: "mac"))
        }
        if let phoneCounters {
            lines.append(contentsOf: renderedCounterLines(phoneCounters, prefix: "phone"))
        }
        if let lastError, !lastError.isEmpty {
            lines.append("last_error=\(lastError)")
        }
        return lines.joined(separator: "\n")
    }

    private func renderedCounterLines(
        _ counters: TunnelCounters,
        prefix: String
    ) -> [String] {
        [
            "\(prefix)_datagrams_from_mac=\(counters.wireGuardDatagramsFromMac)",
            "\(prefix)_datagrams_to_mac=\(counters.wireGuardDatagramsToMac)",
            "\(prefix)_datagrams_to_server=\(counters.wireGuardDatagramsToServer)",
            "\(prefix)_datagrams_from_server=\(counters.wireGuardDatagramsFromServer)",
            "\(prefix)_dropped=\(counters.droppedWireGuardDatagrams)",
            "\(prefix)_bytes_in=\(counters.relayBytesIn)",
            "\(prefix)_bytes_out=\(counters.relayBytesOut)",
        ]
    }
}

public struct TunnelControlFailure: Sendable {
    public var errorCode: TunnelControlErrorCode
    public var message: String

    public init(errorCode: TunnelControlErrorCode, message: String) {
        self.errorCode = errorCode
        self.message = message
    }
}

public struct TunnelRPCFailure: Sendable {
    public var code: String
    public var message: String
    public var cause: String?

    public init(code: String, message: String, cause: String?) {
        self.code = code
        self.message = message
        self.cause = cause
    }
}

public enum TunnelDaemonError: LocalizedError, Sendable {
    case controlFailure(TunnelControlFailure)
    case daemonUnavailable(String)
    case rpcFailure(TunnelRPCFailure)
    case transportFailure(String)
    case usage(String)

    public var errorDescription: String? {
        switch self {
        case .controlFailure(let failure):
            return failure.message
        case .daemonUnavailable(let endpoint):
            return "CellTunnelAgent is not running at \(endpoint)"
        case .rpcFailure(let failure):
            if let cause = failure.cause {
                if !cause.isEmpty {
                    return "rpc code=\(failure.code) message=\(failure.message) cause=\(cause)"
                }
            }
            return "rpc code=\(failure.code) message=\(failure.message)"
        case .transportFailure(let message):
            return message
        case .usage(let message):
            return message
        }
    }

    public var renderedOutput: String {
        switch self {
        case .controlFailure(let failure):
            return [
                "error_kind=control",
                "error_code=\(failure.errorCode.rawValue)",
                "message=\(failure.message)",
            ].joined(separator: "\n")
        case .daemonUnavailable(let socketPath):
            return [
                "error_kind=daemon_unavailable",
                "socket_path=\(socketPath)",
            ].joined(separator: "\n")
        case .rpcFailure(let failure):
            var lines = [
                "error_kind=rpc",
                "error_code=\(failure.code)",
                "message=\(failure.message)",
            ]
            if let cause = failure.cause {
                if !cause.isEmpty {
                    lines.append("cause=\(cause)")
                }
            }
            return lines.joined(separator: "\n")
        case .transportFailure(let message):
            return [
                "error_kind=transport",
                "message=\(message)",
            ].joined(separator: "\n")
        case .usage(let message):
            return [
                "error_kind=usage",
                "message=\(message)",
            ].joined(separator: "\n")
        }
    }
}

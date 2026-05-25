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

public struct TunnelRelayEndpoint: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var addressFamily: TunnelAddressFamily

    public init(host: String, port: Int, addressFamily: TunnelAddressFamily = .unspecified) {
        self.host = host
        self.port = port
        self.addressFamily = addressFamily
    }

    public init(proto: CTControlV1_RelayEndpoint) {
        self.init(
            host: proto.host,
            port: Int(proto.port),
            addressFamily: TunnelAddressFamily(proto: proto.addressFamily)
        )
    }

    public var socketAddress: String {
        if host.hasPrefix(usbmuxdEndpointPrefix) {
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

        if trimmedArgument.hasPrefix(usbmuxdEndpointPrefix) {
            let body = String(trimmedArgument.dropFirst(usbmuxdEndpointPrefix.count))
            guard let lastColonIndex = body.lastIndex(of: ":") else {
                throw TunnelDaemonError.controlFailure(
                    TunnelControlFailure(
                        errorCode: .invalidRelayEndpoint, message: "invalid usbmuxd relay endpoint")
                )
            }
            let udid = String(body[..<lastColonIndex])
            let portString = String(body[body.index(after: lastColonIndex)...])
            guard !udid.isEmpty, let port = Int(portString), port > 0 else {
                throw TunnelDaemonError.controlFailure(
                    TunnelControlFailure(
                        errorCode: .invalidRelayEndpoint, message: "invalid usbmuxd relay endpoint")
                )
            }
            return Self(host: "\(usbmuxdEndpointPrefix)\(udid)", port: port, addressFamily: .unspecified)
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

    public var displayName: String {
        if let preferredEndpoint {
            return "\(serviceName) \(preferredEndpoint.socketAddress)"
        }
        return serviceName
    }

    public init(proto: CTControlV1_RelayService) {
        let endpoints = proto.endpoints.map(TunnelRelayEndpoint.init(proto:))
        let preferredEndpoint =
            proto.hasPreferredEndpoint ? TunnelRelayEndpoint(proto: proto.preferredEndpoint) : nil
        id = proto.identity.serviceID
        serviceName = proto.identity.serviceName
        serviceType = proto.identity.serviceType
        domain = proto.identity.domain
        interfaceIndex = Int(proto.identity.interfaceIndex)
        hostName = proto.hostName
        self.endpoints = endpoints
        self.preferredEndpoint = preferredEndpoint
        isSelected = proto.isSelected
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

    public init(proto: CTControlV1_DiscoveryState) {
        self.init(
            phase: TunnelDiscoveryPhase(proto: proto.phase),
            services: proto.services.map(TunnelRelayService.init(proto:)),
            selectedServiceID: proto.selectedServiceID.isEmpty ? nil : proto.selectedServiceID,
            selectedEndpoint: proto.hasSelectedEndpoint
                ? TunnelRelayEndpoint(proto: proto.selectedEndpoint) : nil,
            lastError: proto.hasLastError ? proto.lastError.message : nil
        )
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
}

public struct TunnelEnvironmentReport: Codable, Equatable, Sendable {
    public var checks: [TunnelEnvironmentCheckResult]

    public init(checks: [TunnelEnvironmentCheckResult] = []) {
        self.checks = checks
    }

    public init(proto: CTControlV1_EnvironmentReport) {
        self.init(
            checks: proto.checks.map { check in
                TunnelEnvironmentCheckResult(name: check.name, value: check.value)
            }
        )
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

    public init(
        running: Bool = false,
        routeState: TunnelRouteState = .notInstalled,
        peerState: TunnelPeerState = .notSelected,
        ipv4Address: String = "",
        ipv6Address: String = "",
        lastError: String? = nil,
        discovery: TunnelDiscoverySnapshot = TunnelDiscoverySnapshot(),
        activeRelayEndpoint: TunnelRelayEndpoint? = nil
    ) {
        self.running = running
        self.routeState = routeState
        self.peerState = peerState
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.lastError = lastError
        self.discovery = discovery
        self.activeRelayEndpoint = activeRelayEndpoint
    }

    public init(proto: CTControlV1_DaemonStatus) {
        self.init(
            running: proto.running,
            routeState: TunnelRouteState(proto: proto.route.state),
            peerState: TunnelPeerState(proto: proto.peer.state),
            ipv4Address: proto.ipv4Address,
            ipv6Address: proto.ipv6Address,
            lastError: proto.hasLastError ? proto.lastError.message : nil,
            discovery: TunnelDiscoverySnapshot(proto: proto.discovery),
            activeRelayEndpoint: proto.hasActiveRelayEndpoint
                ? TunnelRelayEndpoint(proto: proto.activeRelayEndpoint)
                : nil
        )
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
        if let lastError, !lastError.isEmpty {
            lines.append("last_error=\(lastError)")
        }
        return lines.joined(separator: "\n")
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
        case .daemonUnavailable(let socketPath):
            return "celltunneld is not running at \(socketPath)"
        case .rpcFailure(let failure):
            if let cause = failure.cause {
                if !cause.isEmpty {
                    return "gRPC code=\(failure.code) message=\(failure.message) cause=\(cause)"
                }
            }
            return "gRPC code=\(failure.code) message=\(failure.message)"
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

extension TunnelAddressFamily {
    init(proto: CTControlV1_AddressFamily) {
        switch proto {
        case .ipv4:
            self = .ipv4
        case .ipv6:
            self = .ipv6
        default:
            self = .unspecified
        }
    }
}

extension TunnelRouteState {
    init(proto: CTControlV1_RouteState) {
        switch proto {
        case .installed:
            self = .installed
        default:
            self = .notInstalled
        }
    }
}

extension TunnelPeerState {
    init(proto: CTControlV1_PeerState) {
        switch proto {
        case .relaySelected:
            self = .relaySelected
        case .wireguardConfigured:
            self = .wireGuardConfigured
        default:
            self = .notSelected
        }
    }
}

extension TunnelDiscoveryPhase {
    init(proto: CTControlV1_DiscoveryPhase) {
        switch proto {
        case .browsing:
            self = .browsing
        case .failed:
            self = .failed
        case .ready:
            self = .ready
        default:
            self = .stopped
        }
    }
}

extension TunnelControlErrorCode {
    init(proto: CTControlV1_ControlErrorCode) {
        switch proto {
        case .discoveryUnavailable:
            self = .discoveryUnavailable
        case .invalidRelayEndpoint:
            self = .invalidRelayEndpoint
        case .missingWireguardConfigPath:
            self = .missingWireGuardConfigPath
        case .relaySelectionRequired:
            self = .relaySelectionRequired
        case .relayServiceNotFound:
            self = .relayServiceNotFound
        case .runtimeStartFailure:
            self = .runtimeStartFailure
        case .internal:
            self = .internal
        default:
            self = .unspecified
        }
    }
}

extension TunnelRelayEndpoint {
    var proto: CTControlV1_RelayEndpoint {
        var proto = CTControlV1_RelayEndpoint()
        proto.host = host
        proto.port = UInt32(port)
        switch addressFamily {
        case .ipv4:
            proto.addressFamily = .ipv4
        case .ipv6:
            proto.addressFamily = .ipv6
        case .unspecified:
            proto.addressFamily = .unspecified
        }
        return proto
    }
}

extension TunnelDaemonError {
    init(proto: CTControlV1_ControlError) {
        self = .controlFailure(
            TunnelControlFailure(
                errorCode: TunnelControlErrorCode(proto: proto.code), message: proto.message)
        )
    }
}

import Foundation

public let agentControlWireVersion = 1

public protocol TunnelControlClientProtocol: Sendable {
    func status() async throws -> TunnelDaemonStatusSnapshot
    func check() async throws -> TunnelEnvironmentReport
    func startTunnel(settings: TunnelStartSettings) async throws -> TunnelDaemonStatusSnapshot
    func stopTunnel() async throws -> TunnelDaemonStatusSnapshot
    func reset() async throws -> TunnelDaemonStatusSnapshot
    func startRelayDiscovery() async throws -> TunnelDiscoverySnapshot
    func stopRelayDiscovery() async throws -> TunnelDiscoverySnapshot
    func listRelayServices() async throws -> TunnelDiscoverySnapshot
    func selectRelayService(serviceID: String) async throws -> TunnelDiscoverySnapshot
}

public enum AgentControlRequest: Codable, Sendable {
    case check
    case listRelayServices
    case reloadTunnel(TunnelStartSettings)
    case reset
    case selectRelayService(serviceID: String)
    case startRelayDiscovery
    case startTunnel(TunnelStartSettings)
    case status
    case stopRelayDiscovery
    case stopTunnel

    private enum CodingKeys: String, CodingKey {
        case kind
        case reloadSettings
        case serviceID
        case startSettings
    }

    private enum Kind: String, Codable {
        case check
        case listRelayServices
        case reloadTunnel
        case reset
        case selectRelayService
        case startRelayDiscovery
        case startTunnel
        case status
        case stopRelayDiscovery
        case stopTunnel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .check:
            self = .check
        case .listRelayServices:
            self = .listRelayServices
        case .reloadTunnel:
            let settings = try container.decode(TunnelStartSettings.self, forKey: .reloadSettings)
            self = .reloadTunnel(settings)
        case .reset:
            self = .reset
        case .selectRelayService:
            let serviceID = try container.decode(String.self, forKey: .serviceID)
            self = .selectRelayService(serviceID: serviceID)
        case .startRelayDiscovery:
            self = .startRelayDiscovery
        case .startTunnel:
            let settings = try container.decode(TunnelStartSettings.self, forKey: .startSettings)
            self = .startTunnel(settings)
        case .status:
            self = .status
        case .stopRelayDiscovery:
            self = .stopRelayDiscovery
        case .stopTunnel:
            self = .stopTunnel
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .check:
            try container.encode(Kind.check, forKey: .kind)
        case .listRelayServices:
            try container.encode(Kind.listRelayServices, forKey: .kind)
        case .reloadTunnel(let settings):
            try container.encode(Kind.reloadTunnel, forKey: .kind)
            try container.encode(settings, forKey: .reloadSettings)
        case .reset:
            try container.encode(Kind.reset, forKey: .kind)
        case .selectRelayService(let serviceID):
            try container.encode(Kind.selectRelayService, forKey: .kind)
            try container.encode(serviceID, forKey: .serviceID)
        case .startRelayDiscovery:
            try container.encode(Kind.startRelayDiscovery, forKey: .kind)
        case .startTunnel(let settings):
            try container.encode(Kind.startTunnel, forKey: .kind)
            try container.encode(settings, forKey: .startSettings)
        case .status:
            try container.encode(Kind.status, forKey: .kind)
        case .stopRelayDiscovery:
            try container.encode(Kind.stopRelayDiscovery, forKey: .kind)
        case .stopTunnel:
            try container.encode(Kind.stopTunnel, forKey: .kind)
        }
    }
}

public struct AgentControlEnvelope: Codable, Sendable {
    public var version: Int
    public var request: AgentControlRequest

    public init(request: AgentControlRequest, version: Int = agentControlWireVersion) {
        self.version = version
        self.request = request
    }
}

public struct AgentControlFailure: Codable, Sendable {
    public var errorCode: TunnelControlErrorCode
    public var message: String

    public init(errorCode: TunnelControlErrorCode, message: String) {
        self.errorCode = errorCode
        self.message = message
    }
}

public struct AgentControlResponse: Codable, Sendable {
    public var version: Int
    public var status: TunnelDaemonStatusSnapshot?
    public var report: TunnelEnvironmentReport?
    public var discovery: TunnelDiscoverySnapshot?
    public var failure: AgentControlFailure?

    public init(
        status: TunnelDaemonStatusSnapshot? = nil,
        report: TunnelEnvironmentReport? = nil,
        discovery: TunnelDiscoverySnapshot? = nil,
        failure: AgentControlFailure? = nil,
        version: Int = agentControlWireVersion
    ) {
        self.version = version
        self.status = status
        self.report = report
        self.discovery = discovery
        self.failure = failure
    }
}

import Foundation

public let providerControlWireVersion = 1

public enum ProviderControlRequest: Codable, Sendable {
    case discoverySnapshot
    case status

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    private enum Kind: String, Codable {
        case discoverySnapshot
        case status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .discoverySnapshot:
            self = .discoverySnapshot
        case .status:
            self = .status
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .discoverySnapshot:
            try container.encode(Kind.discoverySnapshot, forKey: .kind)
        case .status:
            try container.encode(Kind.status, forKey: .kind)
        }
    }
}

public struct ProviderControlEnvelope: Codable, Sendable {
    public var version: Int
    public var request: ProviderControlRequest

    public init(request: ProviderControlRequest, version: Int = providerControlWireVersion) {
        self.version = version
        self.request = request
    }
}

public struct ProviderControlResponse: Codable, Sendable {
    public var version: Int
    public var status: TunnelDaemonStatusSnapshot?
    public var discovery: TunnelDiscoverySnapshot?
    public var failureMessage: String?

    public init(
        status: TunnelDaemonStatusSnapshot? = nil,
        discovery: TunnelDiscoverySnapshot? = nil,
        failureMessage: String? = nil,
        version: Int = providerControlWireVersion
    ) {
        self.version = version
        self.status = status
        self.discovery = discovery
        self.failureMessage = failureMessage
    }
}

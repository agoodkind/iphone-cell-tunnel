import Foundation

public let relayControlServiceType = "_cellrelaycontrol._tcp"
public let relayControlListenerDefaultPort: UInt16 = 51_823
public let relayControlWireVersion: Int = 1

public enum RelayControlMessage: Codable, Sendable, Equatable {
    case setServerEndpoint(SetServerEndpoint)
    case acknowledge(Acknowledge)
    case status(Status)
    case error(Failure)

    public struct SetServerEndpoint: Codable, Sendable, Equatable {
        public var version: Int
        public var endpoint: RelayEndpoint

        public init(endpoint: RelayEndpoint, version: Int = relayControlWireVersion) {
            self.endpoint = endpoint
            self.version = version
        }
    }

    public struct Acknowledge: Codable, Sendable, Equatable {
        public var version: Int
        public var requestKind: String
        public var detail: String?

        public init(
            requestKind: String,
            detail: String? = nil,
            version: Int = relayControlWireVersion
        ) {
            self.requestKind = requestKind
            self.detail = detail
            self.version = version
        }
    }

    public struct Status: Codable, Sendable, Equatable {
        public var version: Int
        public var hasCellularPath: Bool
        public var cellularInterface: String?
        public var lastError: String?

        public init(
            hasCellularPath: Bool,
            cellularInterface: String? = nil,
            lastError: String? = nil,
            version: Int = relayControlWireVersion
        ) {
            self.hasCellularPath = hasCellularPath
            self.cellularInterface = cellularInterface
            self.lastError = lastError
            self.version = version
        }
    }

    public struct Failure: Codable, Sendable, Equatable {
        public var version: Int
        public var code: String
        public var message: String

        public init(code: String, message: String, version: Int = relayControlWireVersion) {
            self.code = code
            self.message = message
            self.version = version
        }
    }

    public var kindLabel: String {
        switch self {
        case .setServerEndpoint:
            return "set-server-endpoint"
        case .acknowledge:
            return "acknowledge"
        case .status:
            return "status"
        case .error:
            return "error"
        }
    }

    public var declaredVersion: Int {
        switch self {
        case .setServerEndpoint(let payload):
            return payload.version
        case .acknowledge(let payload):
            return payload.version
        case .status(let payload):
            return payload.version
        case .error(let payload):
            return payload.version
        }
    }
}

public enum RelayControlCodecError: Error, Equatable {
    case unsupportedVersion(Int)
    case payloadTooLarge(Int)
    case truncatedFrame
}

public enum RelayControlMessageCodec {
    public static let maxPayloadBytes = 1 << 20

    public static func encode(_ message: RelayControlMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
        guard payload.count <= maxPayloadBytes else {
            throw RelayControlCodecError.payloadTooLarge(payload.count)
        }
        return payload
    }

    public static func decode(_ payload: Data) throws -> RelayControlMessage {
        let decoder = JSONDecoder()
        let message = try decoder.decode(RelayControlMessage.self, from: payload)
        guard message.declaredVersion == relayControlWireVersion else {
            throw RelayControlCodecError.unsupportedVersion(message.declaredVersion)
        }
        return message
    }
}

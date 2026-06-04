//
//  RelayControlMessage.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

public let relayControlServiceType = "_cellrelaycontrol._tcp"
public let relayControlListenerDefaultPort: UInt16 = 51_823
public let relayControlWireVersion: Int = 1

public enum RelayControlMessage: Codable, Sendable, Equatable {
    case acknowledge(Acknowledge)
    case error(Failure)
    case routeState(RouteState)
    case setRoutingEnabled(SetRoutingEnabled)
    case setServerEndpoint(SetServerEndpoint)
    case status(Status)

    /// Carries the user's passthrough-versus-routing choice from the iPhone app to
    /// the agent over the control link. The agent installs the program routes only
    /// while this is on, so the default is passthrough.
    public struct SetRoutingEnabled: Codable, Sendable, Equatable {
        public var version: Int
        public var enabled: Bool

        public init(enabled: Bool, version: Int = relayControlWireVersion) {
            self.enabled = enabled
            self.version = version
        }
    }

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
        public var counters: TunnelCounters?

        public init(
            hasCellularPath: Bool,
            cellularInterface: String? = nil,
            lastError: String? = nil,
            counters: TunnelCounters? = nil,
            version: Int = relayControlWireVersion
        ) {
            self.hasCellularPath = hasCellularPath
            self.cellularInterface = cellularInterface
            self.lastError = lastError
            self.counters = counters
            self.version = version
        }
    }

    /// Carries the agent's confirmed route state to the iPhone over the control
    /// link, so the app reports installed routes from the agent's truth rather than
    /// the local routing intent. The agent sends it after the Mac extension applies
    /// the route change and when a link transition withdraws routes.
    public struct RouteState: Codable, Sendable, Equatable {
        public var version: Int
        public var installed: Bool

        public init(installed: Bool, version: Int = relayControlWireVersion) {
            self.installed = installed
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
        case .setRoutingEnabled:
            return "set-routing-enabled"
        case .acknowledge:
            return "acknowledge"
        case .status:
            return "status"
        case .error:
            return "error"
        case .routeState:
            return "route-state"
        }
    }

    public var declaredVersion: Int {
        switch self {
        case .setServerEndpoint(let payload):
            return payload.version
        case .setRoutingEnabled(let payload):
            return payload.version
        case .acknowledge(let payload):
            return payload.version
        case .status(let payload):
            return payload.version
        case .error(let payload):
            return payload.version
        case .routeState(let payload):
            return payload.version
        }
    }
}

// MARK: - RelayControlCodecError

public enum RelayControlCodecError: Error, Equatable {
    case payloadTooLarge(Int)
    case truncatedFrame
    case unsupportedVersion(Int)
}

// MARK: - RelayControlMessageCodec

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

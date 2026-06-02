//
//  ProviderControlRequest.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

public let providerControlWireVersion = 1

public enum ProviderControlRequest: Codable, Sendable {
    case discoverySnapshot
    case reloadConfig(text: String)
    case setRouteState(installed: Bool)
    case status

    private enum CodingKeys: String, CodingKey {
        case configText
        case installed
        case kind
    }

    private enum Kind: String, Codable {
        case discoverySnapshot
        case reloadConfig
        case setRouteState
        case status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .discoverySnapshot:
            self = .discoverySnapshot
        case .reloadConfig:
            let text = try container.decode(String.self, forKey: .configText)
            self = .reloadConfig(text: text)
        case .setRouteState:
            let installed = try container.decode(Bool.self, forKey: .installed)
            self = .setRouteState(installed: installed)
        case .status:
            self = .status
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .discoverySnapshot:
            try container.encode(Kind.discoverySnapshot, forKey: .kind)
        case .reloadConfig(let text):
            try container.encode(Kind.reloadConfig, forKey: .kind)
            try container.encode(text, forKey: .configText)
        case .setRouteState(let installed):
            try container.encode(Kind.setRouteState, forKey: .kind)
            try container.encode(installed, forKey: .installed)
        case .status:
            try container.encode(Kind.status, forKey: .kind)
        }
    }
}

// MARK: - ProviderControlEnvelope

public struct ProviderControlEnvelope: Codable, Sendable {
    public var version: Int
    public var request: ProviderControlRequest

    public init(request: ProviderControlRequest, version: Int = providerControlWireVersion) {
        self.version = version
        self.request = request
    }
}

// MARK: - ProviderControlResponse

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

//
//  AgentControlRequest.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

public let agentControlWireVersion = 2

public protocol TunnelControlClientProtocol: Sendable {
  func check() async throws -> TunnelEnvironmentReport
  /// Makes a stored config active and starts the tunnel with it.
  func activateConfig(id: UUID) async throws -> TunnelDaemonStatusSnapshot
  /// Deletes a stored config, stopping the tunnel first when it is the active one.
  func deleteConfig(id: UUID) async throws -> TunnelDaemonStatusSnapshot
  /// Returns the secret text of a stored config, fetched only for editing.
  func getConfigText(id: UUID) async throws -> String
  /// Validates, stores, and activates a config, then returns the refreshed status
  /// carrying the updated library. Relay start is left to the explicit start action.
  func importConfig(name: String, text: String) async throws -> TunnelDaemonStatusSnapshot
  func listRelayServices() async throws -> TunnelDiscoverySnapshot
  func reloadTunnel(settings: TunnelStartSettings) async throws -> TunnelDaemonStatusSnapshot
  /// Renames a stored config.
  func renameConfig(id: UUID, name: String) async throws -> TunnelDaemonStatusSnapshot
  func reset() async throws -> TunnelDaemonStatusSnapshot
  /// Saves edited config text and reloads the tunnel when that config is active.
  func saveConfigEdit(id: UUID, text: String) async throws -> TunnelDaemonStatusSnapshot
  /// Selects which dialed-in iPhone the agent routes egress through, by the roster id.
  func selectEgressPeer(peerID: String) async throws -> TunnelDaemonStatusSnapshot
  func selectRelayService(serviceID: String) async throws -> TunnelDiscoverySnapshot
  /// Marks a stored config active without starting the tunnel.
  func setActiveConfig(id: UUID) async throws -> TunnelDaemonStatusSnapshot
  func setRoutingEnabled(_ enabled: Bool) async throws -> TunnelDaemonStatusSnapshot
  func startPairing() async throws -> TunnelDaemonStatusSnapshot
  func startRelay() async throws -> TunnelDaemonStatusSnapshot
  func startRelayDiscovery() async throws -> TunnelDiscoverySnapshot
  func startTunnel(settings: TunnelStartSettings) async throws -> TunnelDaemonStatusSnapshot
  func status() async throws -> TunnelDaemonStatusSnapshot
  func stopRelayDiscovery() async throws -> TunnelDiscoverySnapshot
  func stopTunnel() async throws -> TunnelDaemonStatusSnapshot
  /// Validates WireGuard configuration text without changing tunnel state.
  func validateConfig(text: String) async throws
}

// MARK: - AgentControlRequest

public enum AgentControlRequest: Codable, Sendable {
  /// Makes a stored config active and starts the tunnel with it.
  case activateConfig(id: UUID)
  case check
  /// Deletes a stored config, stopping the tunnel first when it is active.
  case deleteConfig(id: UUID)
  /// Returns the secret text of a stored config, fetched only for editing.
  case getConfigText(id: UUID)
  /// Validates, stores, and activates a config from its text; relay start is left to
  /// the explicit start action.
  case importConfig(name: String, text: String)
  case listRelayServices
  case reloadTunnel(TunnelStartSettings)
  /// Renames a stored config.
  case renameConfig(id: UUID, name: String)
  case reset
  /// Saves edited config text and reloads the tunnel when that config is active.
  case saveConfigEdit(id: UUID, text: String)
  /// Selects which connected iPhone the agent routes egress through, by the
  /// per-connection id the roster carries.
  case selectEgressPeer(peerID: String)
  case selectRelayService(serviceID: String)
  case setActiveConfig(id: UUID)
  case setRoutingEnabled(enabled: Bool)
  case startPairing
  case startRelay
  case startRelayDiscovery
  case startTunnel(TunnelStartSettings)
  case status
  case stopRelayDiscovery
  case stopTunnel
  /// Validates WireGuard configuration text without changing tunnel state.
  case validateConfig(text: String)

  private enum CodingKeys: String, CodingKey {
    case configID
    case configName
    case configText
    case kind
    case peerID
    case reloadSettings
    case routingEnabled
    case serviceID
    case startSettings
  }

  private enum Kind: String, Codable {
    case activateConfig
    case check
    case deleteConfig
    case getConfigText
    case importConfig
    case listRelayServices
    case reloadTunnel
    case renameConfig
    case reset
    case saveConfigEdit
    case selectEgressPeer
    case selectRelayService
    case setActiveConfig
    case setRoutingEnabled
    case startPairing
    case startRelay
    case startRelayDiscovery
    case startTunnel
    case status
    case stopRelayDiscovery
    case stopTunnel
    case validateConfig
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    self = try Self.decodeRequest(kind: kind, from: container)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try Self.encodeRequest(self, into: &container)
  }

  private static func decodeRequest(
    kind: Kind,
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> AgentControlRequest {
    switch kind {
    case .activateConfig:
      return .activateConfig(id: try container.decode(UUID.self, forKey: .configID))
    case .check:
      return .check
    case .deleteConfig:
      return .deleteConfig(id: try container.decode(UUID.self, forKey: .configID))
    case .getConfigText:
      return .getConfigText(id: try container.decode(UUID.self, forKey: .configID))
    case .importConfig:
      return .importConfig(
        name: try container.decode(String.self, forKey: .configName),
        text: try container.decode(String.self, forKey: .configText)
      )
    case .listRelayServices:
      return .listRelayServices
    case .reloadTunnel:
      return .reloadTunnel(
        try container.decode(TunnelStartSettings.self, forKey: .reloadSettings))
    case .renameConfig:
      return .renameConfig(
        id: try container.decode(UUID.self, forKey: .configID),
        name: try container.decode(String.self, forKey: .configName)
      )
    case .reset:
      return .reset
    case .saveConfigEdit:
      return .saveConfigEdit(
        id: try container.decode(UUID.self, forKey: .configID),
        text: try container.decode(String.self, forKey: .configText)
      )
    case .selectEgressPeer:
      return .selectEgressPeer(peerID: try container.decode(String.self, forKey: .peerID))
    case .selectRelayService:
      return .selectRelayService(
        serviceID: try container.decode(String.self, forKey: .serviceID))
    case .setActiveConfig:
      return .setActiveConfig(id: try container.decode(UUID.self, forKey: .configID))
    case .setRoutingEnabled:
      return .setRoutingEnabled(
        enabled: try container.decode(Bool.self, forKey: .routingEnabled))
    case .startPairing:
      return .startPairing
    case .startRelay:
      return .startRelay
    case .startRelayDiscovery:
      return .startRelayDiscovery
    case .startTunnel:
      return .startTunnel(
        try container.decode(TunnelStartSettings.self, forKey: .startSettings))
    case .status:
      return .status
    case .stopRelayDiscovery:
      return .stopRelayDiscovery
    case .stopTunnel:
      return .stopTunnel
    case .validateConfig:
      return .validateConfig(text: try container.decode(String.self, forKey: .configText))
    }
  }

  private static func encodeRequest(
    _ request: AgentControlRequest,
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    switch request {
    case .activateConfig(let id):
      try container.encode(Kind.activateConfig, forKey: .kind)
      try container.encode(id, forKey: .configID)
    case .check: try encodeKind(.check, into: &container)
    case .deleteConfig(let id):
      try container.encode(Kind.deleteConfig, forKey: .kind)
      try container.encode(id, forKey: .configID)
    case .getConfigText(let id):
      try container.encode(Kind.getConfigText, forKey: .kind)
      try container.encode(id, forKey: .configID)
    case let .importConfig(name, text):
      try container.encode(Kind.importConfig, forKey: .kind)
      try container.encode(name, forKey: .configName)
      try container.encode(text, forKey: .configText)
    case .listRelayServices: try encodeKind(.listRelayServices, into: &container)
    case .reloadTunnel(let settings):
      try container.encode(Kind.reloadTunnel, forKey: .kind)
      try container.encode(settings, forKey: .reloadSettings)
    case let .renameConfig(id, name):
      try container.encode(Kind.renameConfig, forKey: .kind)
      try container.encode(id, forKey: .configID)
      try container.encode(name, forKey: .configName)
    case .reset: try encodeKind(.reset, into: &container)
    case let .saveConfigEdit(id, text):
      try container.encode(Kind.saveConfigEdit, forKey: .kind)
      try container.encode(id, forKey: .configID)
      try container.encode(text, forKey: .configText)
    case .selectEgressPeer(let peerID):
      try container.encode(Kind.selectEgressPeer, forKey: .kind)
      try container.encode(peerID, forKey: .peerID)
    case .selectRelayService(let serviceID):
      try container.encode(Kind.selectRelayService, forKey: .kind)
      try container.encode(serviceID, forKey: .serviceID)
    case .setActiveConfig(let id):
      try container.encode(Kind.setActiveConfig, forKey: .kind)
      try container.encode(id, forKey: .configID)
    case .setRoutingEnabled(let enabled):
      try container.encode(Kind.setRoutingEnabled, forKey: .kind)
      try container.encode(enabled, forKey: .routingEnabled)
    case .startPairing: try encodeKind(.startPairing, into: &container)
    case .startRelay: try encodeKind(.startRelay, into: &container)
    case .startRelayDiscovery: try encodeKind(.startRelayDiscovery, into: &container)
    case .startTunnel(let settings):
      try container.encode(Kind.startTunnel, forKey: .kind)
      try container.encode(settings, forKey: .startSettings)
    case .status: try encodeKind(.status, into: &container)
    case .stopRelayDiscovery: try encodeKind(.stopRelayDiscovery, into: &container)
    case .stopTunnel: try encodeKind(.stopTunnel, into: &container)
    case .validateConfig(let text):
      try container.encode(Kind.validateConfig, forKey: .kind)
      try container.encode(text, forKey: .configText)
    }
  }

  private static func encodeKind(
    _ kind: Kind,
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(kind, forKey: .kind)
  }
}

// MARK: - AgentControlEnvelope

public struct AgentControlEnvelope: Codable, Sendable {
  public var version: Int
  public var request: AgentControlRequest

  public init(request: AgentControlRequest, version: Int = agentControlWireVersion) {
    self.version = version
    self.request = request
  }
}

// MARK: - AgentControlFailure

public struct AgentControlFailure: Codable, Sendable {
  public var errorCode: TunnelControlErrorCode
  public var message: String

  public init(errorCode: TunnelControlErrorCode, message: String) {
    self.errorCode = errorCode
    self.message = message
  }
}

// MARK: - AgentControlResponse

public struct AgentControlResponse: Codable, Sendable {
  public var version: Int
  public var status: TunnelDaemonStatusSnapshot?
  public var report: TunnelEnvironmentReport?
  public var discovery: TunnelDiscoverySnapshot?
  public var failure: AgentControlFailure?
  /// The secret config text returned only by `getConfigText`, never logged and
  /// never set on any other response.
  public var configText: String?

  public init(
    status: TunnelDaemonStatusSnapshot? = nil,
    report: TunnelEnvironmentReport? = nil,
    discovery: TunnelDiscoverySnapshot? = nil,
    failure: AgentControlFailure? = nil,
    configText: String? = nil,
    version: Int = agentControlWireVersion
  ) {
    self.version = version
    self.status = status
    self.report = report
    self.discovery = discovery
    self.failure = failure
    self.configText = configText
  }
}

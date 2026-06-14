//
//  AgentControlRequest.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

public let agentControlWireVersion = 1

public protocol TunnelControlClientProtocol: Sendable {
  func status() async throws -> TunnelDaemonStatusSnapshot
  func check() async throws -> TunnelEnvironmentReport
  func startTunnel(settings: TunnelStartSettings) async throws -> TunnelDaemonStatusSnapshot
  /// Validates WireGuard configuration text without changing tunnel state.
  func validateConfig(text: String) async throws
  func stopTunnel() async throws -> TunnelDaemonStatusSnapshot
  func reset() async throws -> TunnelDaemonStatusSnapshot
  func startRelayDiscovery() async throws -> TunnelDiscoverySnapshot
  func stopRelayDiscovery() async throws -> TunnelDiscoverySnapshot
  func listRelayServices() async throws -> TunnelDiscoverySnapshot
  func selectRelayService(serviceID: String) async throws -> TunnelDiscoverySnapshot
  /// Selects which dialed-in iPhone the agent routes egress through, by the roster id.
  func selectEgressPeer(peerID: String) async throws -> TunnelDaemonStatusSnapshot
  /// Validates, stores, activates, and starts a config, then returns the refreshed
  /// status carrying the updated library.
  func importConfig(name: String, text: String) async throws -> TunnelDaemonStatusSnapshot
  /// Makes a stored config active and starts the tunnel with it.
  func activateConfig(id: UUID) async throws -> TunnelDaemonStatusSnapshot
  /// Saves edited config text and reloads the tunnel when that config is active.
  func saveConfigEdit(id: UUID, text: String) async throws -> TunnelDaemonStatusSnapshot
  /// Renames a stored config.
  func renameConfig(id: UUID, name: String) async throws -> TunnelDaemonStatusSnapshot
  /// Deletes a stored config, stopping the tunnel first when it is the active one.
  func deleteConfig(id: UUID) async throws -> TunnelDaemonStatusSnapshot
  /// Returns the secret text of a stored config, fetched only for editing.
  func getConfigText(id: UUID) async throws -> String
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
  /// Validates, stores, activates, and starts a config from its text.
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
  case setRoutingEnabled(enabled: Bool)
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
    case setRoutingEnabled
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
    switch kind {
    case .activateConfig:
      let id = try container.decode(UUID.self, forKey: .configID)
      self = .activateConfig(id: id)
    case .check:
      self = .check
    case .deleteConfig:
      let id = try container.decode(UUID.self, forKey: .configID)
      self = .deleteConfig(id: id)
    case .getConfigText:
      let id = try container.decode(UUID.self, forKey: .configID)
      self = .getConfigText(id: id)
    case .importConfig:
      let name = try container.decode(String.self, forKey: .configName)
      let text = try container.decode(String.self, forKey: .configText)
      self = .importConfig(name: name, text: text)
    case .listRelayServices:
      self = .listRelayServices
    case .reloadTunnel:
      let settings = try container.decode(TunnelStartSettings.self, forKey: .reloadSettings)
      self = .reloadTunnel(settings)
    case .renameConfig:
      let id = try container.decode(UUID.self, forKey: .configID)
      let name = try container.decode(String.self, forKey: .configName)
      self = .renameConfig(id: id, name: name)
    case .reset:
      self = .reset
    case .saveConfigEdit:
      let id = try container.decode(UUID.self, forKey: .configID)
      let text = try container.decode(String.self, forKey: .configText)
      self = .saveConfigEdit(id: id, text: text)
    case .selectRelayService:
      let serviceID = try container.decode(String.self, forKey: .serviceID)
      self = .selectRelayService(serviceID: serviceID)
    case .selectEgressPeer:
      let peerID = try container.decode(String.self, forKey: .peerID)
      self = .selectEgressPeer(peerID: peerID)
    case .setRoutingEnabled:
      let enabled = try container.decode(Bool.self, forKey: .routingEnabled)
      self = .setRoutingEnabled(enabled: enabled)
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
    case .validateConfig:
      let text = try container.decode(String.self, forKey: .configText)
      self = .validateConfig(text: text)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .activateConfig(let id):
      try container.encode(Kind.activateConfig, forKey: .kind)
      try container.encode(id, forKey: .configID)
    case .check:
      try container.encode(Kind.check, forKey: .kind)
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
    case .listRelayServices:
      try container.encode(Kind.listRelayServices, forKey: .kind)
    case .reloadTunnel(let settings):
      try container.encode(Kind.reloadTunnel, forKey: .kind)
      try container.encode(settings, forKey: .reloadSettings)
    case let .renameConfig(id, name):
      try container.encode(Kind.renameConfig, forKey: .kind)
      try container.encode(id, forKey: .configID)
      try container.encode(name, forKey: .configName)
    case .reset:
      try container.encode(Kind.reset, forKey: .kind)
    case let .saveConfigEdit(id, text):
      try container.encode(Kind.saveConfigEdit, forKey: .kind)
      try container.encode(id, forKey: .configID)
      try container.encode(text, forKey: .configText)
    case .selectRelayService(let serviceID):
      try container.encode(Kind.selectRelayService, forKey: .kind)
      try container.encode(serviceID, forKey: .serviceID)
    case .selectEgressPeer(let peerID):
      try container.encode(Kind.selectEgressPeer, forKey: .kind)
      try container.encode(peerID, forKey: .peerID)
    case .setRoutingEnabled(let enabled):
      try container.encode(Kind.setRoutingEnabled, forKey: .kind)
      try container.encode(enabled, forKey: .routingEnabled)
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
    case .validateConfig(let text):
      try container.encode(Kind.validateConfig, forKey: .kind)
      try container.encode(text, forKey: .configText)
    }
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

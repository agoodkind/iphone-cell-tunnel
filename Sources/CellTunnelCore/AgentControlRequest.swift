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
}

// MARK: - AgentControlRequest

public enum AgentControlRequest: Codable, Sendable {
  case check
  case listRelayServices
  case reloadTunnel(TunnelStartSettings)
  case reset
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
    case configText
    case kind
    case peerID
    case reloadSettings
    case routingEnabled
    case serviceID
    case startSettings
  }

  private enum Kind: String, Codable {
    case check
    case listRelayServices
    case reloadTunnel
    case reset
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

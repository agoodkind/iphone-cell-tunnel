//
//  TunnelControlCLIAction.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)
private let peerListingIndexBase = 1
private let optionArgumentStride = 2
private let noRelayPeersMessage = "no peers found"

public enum TunnelControlCLIAction: Equatable, Sendable {
  case check
  case peers
  case reset
  case select(reference: String)
  case start(TunnelStartSettings)
  case startDiscovery
  case status
  case stop
  case stopDiscovery

  public static func parse(arguments: [String]) throws -> Self {
    logger.notice(
      "parsing tunnel control cli action argumentCount=\(arguments.count, privacy: .public)")
    guard let command = arguments.first else {
      throw TunnelDaemonError.usage("missing command")
    }

    switch command {
    case "status":
      return .status
    case "check":
      return .check
    case "peers":
      return .peers
    case "start-discovery":
      return .startDiscovery
    case "stop-discovery":
      return .stopDiscovery
    case "select":
      return try .select(reference: parseSelect(arguments: Array(arguments.dropFirst())))
    case "stop":
      return .stop
    case "reset":
      return .reset
    case "start":
      return .start(try parseStart(arguments: Array(arguments.dropFirst())))
    default:
      throw TunnelDaemonError.usage("unknown command: \(command)")
    }
  }

  private static func parseSelect(arguments: [String]) throws -> String {
    guard let reference = arguments.first else {
      throw TunnelDaemonError.usage("select requires <n>")
    }
    guard arguments.count == 1 else {
      throw TunnelDaemonError.usage("select accepts only <n>")
    }
    let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw TunnelDaemonError.usage("select <n> must not be empty")
    }
    return trimmed
  }

  private static func parseStart(arguments: [String]) throws -> TunnelStartSettings {
    var configPath = ""
    var relayEndpoint: TunnelRelayEndpoint?

    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--config":
        guard index + 1 < arguments.count else {
          throw TunnelDaemonError.usage("missing value for --config")
        }
        configPath = arguments[index + 1]
        index += optionArgumentStride
      case "--relay":
        guard index + 1 < arguments.count else {
          throw TunnelDaemonError.usage("missing value for --relay")
        }
        relayEndpoint = try TunnelRelayEndpoint.parse(argument: arguments[index + 1])
        index += optionArgumentStride
      default:
        throw TunnelDaemonError.usage("unknown start option: \(argument)")
      }
    }

    guard !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TunnelDaemonError.usage("start requires --config <path>")
    }
    return TunnelStartSettings(wireGuardConfigPath: configPath, relayEndpoint: relayEndpoint)
  }
}

// MARK: - TunnelControlCLIExecutor

public struct TunnelControlCLIExecutor: Sendable {
  private let client: any TunnelControlClientProtocol

  public init(client: any TunnelControlClientProtocol) {
    self.client = client
  }

  public func run(action: TunnelControlCLIAction) async throws -> String {
    logger.notice("executing tunnel control cli action")
    switch action {
    case .status:
      let status = try await client.status()
      return status.renderedOutput
    case .check:
      let report = try await client.check()
      return report.renderedOutput
    case .peers:
      return try await listPeers()
    case .startDiscovery:
      let snapshot = try await client.startRelayDiscovery()
      return snapshot.renderedOutput
    case .stopDiscovery:
      let snapshot = try await client.stopRelayDiscovery()
      return snapshot.renderedOutput
    case .select(let reference):
      return try await selectPeer(reference: reference)
    case .start(let settings):
      let status = try await client.startTunnel(settings: settings)
      return status.renderedOutput
    case .stop:
      let status = try await client.stopTunnel()
      return status.renderedOutput
    case .reset:
      let status = try await client.reset()
      return status.renderedOutput
    }
  }

  private func listPeers() async throws -> String {
    let snapshot = try await client.status()
    return renderPeerListing(peers: snapshot.connectedPeers ?? [])
  }

  private func selectPeer(reference: String) async throws -> String {
    let peerID = try await resolvePeerID(reference: reference)
    let snapshot = try await client.selectEgressPeer(peerID: peerID)
    return snapshot.renderedOutput
  }

  // Resolves a 1-based index into the current roster to its peer id. Selection is
  // index-only because a roster id is an opaque numeric token, indistinguishable from
  // an index, so a non-integer reference is a usage error.
  private func resolvePeerID(reference: String) async throws -> String {
    guard let index = Int(reference) else {
      throw TunnelDaemonError.usage("select requires a 1-based index from `peers`")
    }
    let snapshot = try await client.status()
    let peers = snapshot.connectedPeers ?? []
    let offset = index - peerListingIndexBase
    guard offset >= 0, offset < peers.count else {
      throw TunnelDaemonError.usage(
        "select index \(index) is out of range (\(peers.count) peers)"
      )
    }
    return peers[offset].id
  }

  // One row per dialed-in iPhone: its name and id, or just its id when the name has not
  // arrived yet, so no device-type word is ever fabricated.
  private func renderPeerListing(peers: [ConnectedPeer]) -> String {
    guard !peers.isEmpty else {
      return noRelayPeersMessage
    }
    var lines: [String] = []
    for (offset, peer) in peers.enumerated() {
      let position = offset + peerListingIndexBase
      var line = "\(position)) \(peer.id)"
      if !peer.name.isEmpty {
        line = "\(position)) \(peer.name)  \(peer.id)"
      }
      if peer.isSelected {
        line += " (selected)"
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}

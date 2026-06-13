//
//  ConnectedPeer.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - ConnectedPeer

/// One iPhone currently holding a control connection to the Mac agent, the unit the
/// Mac roster lists and selects egress through. It is distinct from a Bonjour
/// `TunnelRelayService` (a dial target the iPhone discovers) and from an
/// `AgentLinkStatus` (one transport interface of the selected iPhone): a
/// `ConnectedPeer` is a whole dialed-in iPhone the Mac may route through.
///
/// `id` is the agent-minted per-connection identifier, stable for the life of the
/// control connection and reused as the relay-session id once the peer is selected.
/// It is not stable across a reconnect, so a redialing iPhone returns as a fresh
/// entry; persisting a selection across reconnects is deliberately out of scope.
public struct ConnectedPeer: Codable, Equatable, Identifiable, Sendable {
  /// The agent-minted per-connection identifier, the value passed back to select
  /// this iPhone for egress.
  public var id: String
  /// The iPhone's display name, its `UIDevice.current.name` carried in the control
  /// status push, or empty before the first status arrives.
  public var name: String
  /// Whether this iPhone is the one the Mac currently routes egress through.
  public var isSelected: Bool

  public init(id: String, name: String, isSelected: Bool) {
    self.id = id
    self.name = name
    self.isSelected = isSelected
  }
}

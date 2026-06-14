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
/// `id` is the iPhone's stable per-install device id when it sends one, so it stays the
/// same across the control-connection reconnects the iPhone takes on every sleep/wake
/// cycle, which lets the Mac re-bind a remembered selection to the same device. An old
/// app that sends no device id falls back to the agent-minted per-connection handle,
/// which is not stable across a reconnect.
public struct ConnectedPeer: Codable, Equatable, Identifiable, Sendable {
  /// The peer's stable device id, or the per-connection handle for an app that sends
  /// none. The value passed back to select this iPhone for egress.
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

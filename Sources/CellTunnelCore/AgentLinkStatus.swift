//
//  AgentLinkStatus.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - TunnelRoutingIntent

/// The user's routing intent as a reported value: on or off. Carried in the
/// status snapshot separately from `TunnelRouteState`, which reports the routes
/// actually installed, so the switch can show the user's choice while the status
/// word shows the live state. An optional of this type reads `nil` from a
/// producer that predates the field.
public enum TunnelRoutingIntent: String, Codable, Equatable, Sendable {
  case off
  case on

  public init(enabled: Bool) {
    self = enabled ? .on : .off
  }

  /// The intent as the boolean the switch binds to.
  public var isEnabled: Bool {
    self == .on
  }
}

// MARK: - AgentLinkStatus

/// One adopted relay link as the agent's bridge holds it, reported in the status
/// snapshot so the full warm-link set is visible from one status call rather than
/// only the carrying link.
public struct AgentLinkStatus: Codable, Equatable, Sendable {
  public var interfaceName: String
  public var linkClass: RelayLinkClass
  public var isCarrying: Bool

  public init(interfaceName: String, linkClass: RelayLinkClass, isCarrying: Bool) {
    self.interfaceName = interfaceName
    self.linkClass = linkClass
    self.isCarrying = isCarrying
  }
}

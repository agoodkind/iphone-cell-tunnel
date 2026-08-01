//
//  RoutingStartReadiness.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

// MARK: - Constants

/// What to tell a person whose Mac has no iPhone dialled in. Routing cannot start
/// without one, and the remedy is on the phone rather than here.
public let noSelectedPeerConnectionMessage =
  "No iPhone is connected. Open Cell Tunnel on your iPhone to connect it."

// MARK: - RoutingStartReadiness

/// Whether routing may start, and why not when it may not.
///
/// This decision was made twice by rules that disagreed. One side asked only whether a
/// configuration was chosen, and showed a live switch whenever it was. The other also
/// required an iPhone to be dialled in, and refused. A person saw a switch they could
/// flip and a refusal when they flipped it.
///
/// The daemon answers this once and publishes the answer, so no client works it out
/// again and no client can disagree with the one that enforces it.
public enum RoutingStartReadiness: String, Codable, Equatable, Sendable {
  /// No configuration is chosen, so there is nothing to route with.
  case noActiveConfig = "no-active-config"
  /// No iPhone is dialled in, so there is nothing to route through.
  case noSelectedPeer = "no-selected-peer"
  /// Routing can start.
  case ready

  /// The failure to report when a request arrives anyway, or nil when it may proceed.
  public var rejectionErrorCode: TunnelControlErrorCode? {
    switch self {
    case .noActiveConfig:
      return .configSelectionRequired
    case .noSelectedPeer:
      return .relaySelectionRequired
    case .ready:
      return nil
    }
  }

  /// What to tell a person, or nil when routing may proceed.
  public var rejectionMessage: String? {
    switch self {
    case .noActiveConfig:
      return noActiveConfigSelectedMessage
    case .noSelectedPeer:
      return noSelectedPeerConnectionMessage
    case .ready:
      return nil
    }
  }

  /// Whether routing may start.
  public var canProceed: Bool {
    self == .ready
  }
}

/// Decides whether routing may start.
///
/// A missing configuration outranks a missing iPhone, because choosing a configuration
/// is the step a person can take here and now. Reporting the phone first would ask them
/// to fix something that would still leave them unable to start.
public func routingStartReadiness(
  hasActiveConfig: Bool,
  hasSelectedPeer: Bool
) -> RoutingStartReadiness {
  guard hasActiveConfig else {
    return .noActiveConfig
  }
  guard hasSelectedPeer else {
    return .noSelectedPeer
  }
  return .ready
}

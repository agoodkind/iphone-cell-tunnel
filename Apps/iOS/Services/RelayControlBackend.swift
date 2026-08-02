//
//  RelayControlBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-21.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - RelayControlBackend

/// The platform-specific source behind the shared relay UI. The iPhone backend
/// drives the on-device relay. The Mac backend reads the agent. The controller
/// owns the poll cadence and the published state, so a backend only brings its
/// session up or down and answers one status reading at a time.
@MainActor
protocol RelayControlBackend {
  /// Brings the platform relay session up.
  func start() async

  /// One status reading, or `nil` when the source is briefly unavailable. A backend
  /// whose source sends readings on its own leaves this alone and offers
  /// `statusUpdates()` instead.
  func sample() async -> RelayStatusSample?

  /// A stream of readings the source sends on its own, or `nil` from a source that has
  /// to be asked. The stream finishing means the source is unreachable, which is how a
  /// caller learns that without asking.
  func statusUpdates() -> AsyncStream<RelayStatusSample>?

  /// Sets the routing choice through the platform control path.
  func setRouting(enabled: Bool) async

  /// Selects the discovered peer to connect to.
  func selectPeer(id: String) async

  /// Selects which dialed-in iPhone the Mac routes egress through.
  func selectEgressPeer(id: String) async

  /// Whether available peers come from the dialed-in roster.
  var usesEgressRoster: Bool { get }
}

// MARK: - Defaults

extension RelayControlBackend {
  func sample() -> RelayStatusSample? {
    nil
  }

  func statusUpdates() -> AsyncStream<RelayStatusSample>? {
    nil
  }

  var usesEgressRoster: Bool {
    false
  }
}

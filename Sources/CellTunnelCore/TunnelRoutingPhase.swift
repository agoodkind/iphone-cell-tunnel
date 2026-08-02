//
//  TunnelRoutingPhase.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-03.
//  Copyright © 2026, all rights reserved.
//

// MARK: - TunnelRoutingPhase

/// Where the producer is between the two settled routing states.
///
/// A client used to work this out by counting status readings after it sent a request,
/// which meant the countdown ran only while the client was reading. An app that was put
/// in the background mid-connect came back to a spinner frozen for the whole time it was
/// away. The producer knows the answer without counting anything, so it says so and no
/// client keeps a timer.
public enum TunnelRoutingPhase: String, Codable, Equatable, Sendable {
  /// Routing was asked for and the routes are not carrying traffic yet.
  case connecting
  /// Routing is off and nothing is installed.
  case idle
  /// Routing is on and the routes are installed.
  case routing
  /// Routing was turned off and the routes have not gone away yet.
  case stopping

  /// Resolves the phase from the intent the producer holds and the routes it has actually
  /// installed.
  ///
  /// The two settled states are both on and both off. The two in between are the ones a
  /// person sees a spinner for, and they are exactly the states where intent and reality
  /// disagree.
  public static func resolve(
    isRoutingEnabled: Bool,
    areRoutesInstalled: Bool
  ) -> TunnelRoutingPhase {
    if isRoutingEnabled {
      return areRoutesInstalled ? .routing : .connecting
    }
    return areRoutesInstalled ? .stopping : .idle
  }
}

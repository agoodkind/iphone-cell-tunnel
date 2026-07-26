//
//  AgentWork.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - AgentWork

/// What the agent is doing, which decides how long it waits before exiting.
///
/// The cases are deliberately separate rather than one flag, because hosting a
/// relay and waiting for a phone mean different things even where they currently
/// share a countdown length. Cutting off a hosted relay strands the phone with no
/// signal, since its data link is UDP and surfaces nothing, while an
/// advertisement nobody answers has to end or the agent stays resident forever.
public enum AgentWork: Sendable {
  /// The control listener is advertising and no phone has connected. Bounded,
  /// because an attempt nobody completes must still release the agent.
  case advertising
  /// A relay bridge was started and is expected to be live. Treated like
  /// advertising rather than given its own length, because the countdown is not
  /// what protects the bridge: the check made when it fires is.
  case hostingRelay
  /// Nothing in flight, so the short countdown applies.
  case idle

  /// How long the agent waits before it considers exiting, given what it is doing.
  ///
  /// The countdown always runs; this only decides its length. Whether the agent
  /// actually exits is settled when it fires, by asking whether a phone would be
  /// stranded, because a bridge can fail and a phone can leave with nothing
  /// announcing either.
  public func idleCountdownSeconds(idle: Double, advertising: Double) -> Double {
    switch self {
    case .advertising, .hostingRelay:
      return advertising
    case .idle:
      return idle
    }
  }
}

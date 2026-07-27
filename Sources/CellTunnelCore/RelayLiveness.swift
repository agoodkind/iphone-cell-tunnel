//
//  RelayLiveness.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

// MARK: - RelayLivenessVerdict

/// What changed about the agent's liveness, rather than what it currently is.
///
/// The caller withdraws or restores routes on a transition, so reporting the
/// state on every observation would make it withdraw repeatedly while nothing
/// had changed.
public enum RelayLivenessVerdict: Equatable, Sendable {
  /// The agent has stopped answering and its routes should be withdrawn.
  case gone
  /// The agent is answering again and its routes can be restored.
  case live
  /// Nothing changed, so the caller does nothing.
  case unchanged
}

// MARK: - RelayLiveness

/// Turns a run of unanswered messages into a decision about whether the agent
/// has gone away.
///
/// The packet tunnel outlives the agent and holds the routes, so it is the only
/// process that can clean up after an agent that crashed, was force quit, or
/// went away with the login session. A dying process runs no code, so the
/// decision cannot wait for the agent to announce anything.
///
/// A single unanswered message means the agent was busy, so acting on one would
/// drop a working tunnel. Requiring several consecutive misses distinguishes a
/// stall from a death.
public struct RelayLiveness: Sendable {
  private let missedRepliesBeforeGone: Int
  private var consecutiveMisses = 0
  private var isGone = false

  public init(missedRepliesBeforeGone: Int) {
    self.missedRepliesBeforeGone = max(1, missedRepliesBeforeGone)
  }

  /// Records that the agent answered.
  public mutating func recordReply() -> RelayLivenessVerdict {
    consecutiveMisses = 0
    guard isGone else {
      return .unchanged
    }
    isGone = false
    return .live
  }

  /// Records that the agent did not answer.
  public mutating func recordMissedReply() -> RelayLivenessVerdict {
    guard !isGone else {
      return .unchanged
    }
    consecutiveMisses += 1
    guard consecutiveMisses >= missedRepliesBeforeGone else {
      return .unchanged
    }
    isGone = true
    return .gone
  }
}

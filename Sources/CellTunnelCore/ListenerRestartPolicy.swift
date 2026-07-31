//
//  ListenerRestartPolicy.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-31.
//  Copyright © 2026, all rights reserved.
//

/// How much longer each attempt waits than the one before it.
private let listenerRestartDelayGrowth = 2

// MARK: - ListenerRestartDecision

/// What to do after the control listener failed.
public enum ListenerRestartDecision: Equatable, Sendable {
  /// Stop rebuilding on this run of failures. A later client request starts a
  /// fresh attempt, which is what keeps a permanent condition from spinning.
  case giveUp
  /// Rebuild the listener after waiting this long.
  case retry(afterMilliseconds: Int)
}

// MARK: - ListenerRestartPolicy

/// Turns a run of control listener failures into a decision about rebuilding it.
///
/// The listener publishes the record the iPhone browses for, and it binds a fixed
/// port. A previous instance still holding that port, or an interface change,
/// fails it while the agent stays healthy in every other respect. Nothing else
/// notices, so without a rebuild the Mac is undiscoverable until someone restarts
/// the agent by hand.
///
/// Rebuilding immediately and forever is the other failure: a port held by another
/// process fails every attempt, and an unbounded loop would log and spin for as
/// long as the agent runs. Waiting longer after each failure, then stopping,
/// bounds that while still recovering from the transient case.
public struct ListenerRestartPolicy: Sendable {
  private let maxAttempts: Int
  private let baseDelayMilliseconds: Int
  private let maxDelayMilliseconds: Int
  private var attempts = 0

  public init(maxAttempts: Int, baseDelayMilliseconds: Int, maxDelayMilliseconds: Int) {
    self.maxAttempts = max(1, maxAttempts)
    self.baseDelayMilliseconds = max(1, baseDelayMilliseconds)
    self.maxDelayMilliseconds = max(max(1, baseDelayMilliseconds), maxDelayMilliseconds)
  }

  /// Records a failure and says whether to rebuild, and after how long.
  ///
  /// Each failure waits twice as long as the one before, up to the cap, so a
  /// condition that clears on its own is recovered from quickly while one that
  /// does not stops being retried.
  public mutating func recordFailure() -> ListenerRestartDecision {
    guard attempts < maxAttempts else {
      return .giveUp
    }
    attempts += 1
    return .retry(afterMilliseconds: delay(forAttempt: attempts))
  }

  /// Records that a listener started, so a later failure is treated as the first
  /// of a new run rather than the continuation of an old one.
  public mutating func recordSuccess() {
    attempts = 0
  }

  /// The wait before the given attempt, doubling each time and capped.
  ///
  /// The doubling is computed by multiplying rather than by raising to a power, so
  /// a large attempt count cannot overflow on its way to being capped.
  private func delay(forAttempt attempt: Int) -> Int {
    var delay = baseDelayMilliseconds
    for _ in 1..<attempt {
      if delay >= maxDelayMilliseconds {
        return maxDelayMilliseconds
      }
      delay *= listenerRestartDelayGrowth
    }
    return min(delay, maxDelayMilliseconds)
  }
}

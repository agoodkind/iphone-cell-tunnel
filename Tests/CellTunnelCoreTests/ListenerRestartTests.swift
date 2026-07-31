//
//  ListenerRestartTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-31.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

// MARK: - ListenerRestartTests

/// Covers the decision that rebuilds a failed control listener.
///
/// The listener publishes the record the iPhone browses for. A failure that is
/// never rebuilt leaves the Mac undiscoverable with no error a person can act on,
/// and a rebuild that never stops spins for as long as the agent runs.
@Suite("Listener restart policy")
struct ListenerRestartTests {
  private func policy() -> ListenerRestartPolicy {
    ListenerRestartPolicy(
      maxAttempts: 4,
      baseDelayMilliseconds: 500,
      maxDelayMilliseconds: 4_000
    )
  }

  /// A port held by a previous instance frees up on its own, so the first failure
  /// is worth retrying rather than reporting.
  @Test("the first failure asks for a rebuild")
  func firstFailureAsksForARebuild() {
    var subject = policy()
    #expect(subject.recordFailure() == .retry(afterMilliseconds: 500))
  }

  /// Each wait doubles, so a condition that has not cleared is asked about less
  /// often rather than hammered.
  @Test("each failure waits longer than the one before")
  func eachFailureWaitsLonger() {
    var subject = policy()
    #expect(subject.recordFailure() == .retry(afterMilliseconds: 500))
    #expect(subject.recordFailure() == .retry(afterMilliseconds: 1_000))
    #expect(subject.recordFailure() == .retry(afterMilliseconds: 2_000))
  }

  /// The wait stops growing, so a long run does not push the next attempt beyond
  /// any time a person would wait.
  @Test("the wait is capped")
  func theWaitIsCapped() {
    var subject = ListenerRestartPolicy(
      maxAttempts: 10,
      baseDelayMilliseconds: 500,
      maxDelayMilliseconds: 1_000
    )
    #expect(subject.recordFailure() == .retry(afterMilliseconds: 500))
    #expect(subject.recordFailure() == .retry(afterMilliseconds: 1_000))
    #expect(subject.recordFailure() == .retry(afterMilliseconds: 1_000))
    #expect(subject.recordFailure() == .retry(afterMilliseconds: 1_000))
  }

  /// A condition that never clears stops being retried, so the agent does not log
  /// and rebuild for the rest of its life.
  @Test("a run of failures stops being retried")
  func aRunOfFailuresStopsBeingRetried() {
    var subject = policy()
    for _ in 1...4 {
      #expect(subject.recordFailure() != .giveUp)
    }
    #expect(subject.recordFailure() == .giveUp)
    #expect(subject.recordFailure() == .giveUp)
  }

  /// A listener that starts clears the run, so an unrelated failure hours later is
  /// retried rather than refused because of failures already recovered from.
  @Test("a start clears the run of failures")
  func aStartClearsTheRun() {
    var subject = policy()
    for _ in 1...4 {
      _ = subject.recordFailure()
    }
    #expect(subject.recordFailure() == .giveUp)

    subject.recordSuccess()

    #expect(subject.recordFailure() == .retry(afterMilliseconds: 500))
  }

  /// A caller asking for nonsense still gets a usable policy rather than a wait of
  /// zero that becomes a spin.
  @Test("unusable settings are corrected rather than obeyed")
  func unusableSettingsAreCorrected() {
    var subject = ListenerRestartPolicy(
      maxAttempts: 0,
      baseDelayMilliseconds: 0,
      maxDelayMilliseconds: -1
    )
    let decision = subject.recordFailure()
    #expect(decision != .giveUp)
    if case .retry(let afterMilliseconds) = decision {
      #expect(afterMilliseconds > 0)
    }
    #expect(subject.recordFailure() == .giveUp)
  }
}

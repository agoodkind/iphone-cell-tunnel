//
//  VPNProfileSaveFailureTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import NetworkExtension
import Testing

// MARK: - VPNProfileSaveFailureTests

/// Covers what a person is told when saving the VPN profile does not work.
///
/// The case that matters is the system refusing to write the profile, which is what
/// declining the permission prompt produces. That reported the system's own text, which
/// names the failure and leaves the reader with nothing to do about it.
///
/// Each case is addressed by the system's own named code rather than by a number, so a
/// test cannot quietly drift from the meaning the system attaches to it.
struct VPNProfileSaveFailureTests {
  private func classify(_ code: NEVPNError.Code) -> VPNProfileSaveFailure? {
    vpnProfileSaveFailure(domain: NEVPNErrorDomain, code: code.rawValue)
  }

  @Test func aRefusedWriteSaysHowToTryAgain() {
    let failure = classify(.configurationReadWriteFailed)

    #expect(failure == .writeRefused)
    #expect(failure?.message.contains("permission") == true)
    #expect(failure?.message.contains("Allow") == true)
  }

  @Test func aStaleProfileSaysToSaveAFreshOne() {
    #expect(classify(.configurationStale) == .stale)
  }

  @Test func aRefusedProfileNamesTheConfiguration() {
    #expect(classify(.configurationInvalid) == .invalid)
  }

  /// A switched-off profile is reported as its own state with its own action, so
  /// classifying it here would give a person two different things to do about one
  /// situation.
  @Test func aSwitchedOffProfileIsLeftToItsOwnState() {
    #expect(classify(.configurationDisabled) == nil)
  }

  /// A failure from anywhere else keeps whatever it already said. Attaching a VPN remedy
  /// to an unrelated failure would send a person somewhere that cannot help.
  @Test func anotherDomainIsNotClassified() {
    #expect(vpnProfileSaveFailure(domain: "NSURLErrorDomain", code: 5) == nil)
  }

  /// A code with no distinct remedy is left alone for the same reason.
  @Test func anUnrecognisedCodeIsNotClassified() {
    #expect(classify(.configurationUnknown) == nil)
  }

  /// Every message names the failure and then the step, so neither half can be shipped
  /// without the other.
  @Test func everyMessageCarriesBothHalves() {
    for failure in [VPNProfileSaveFailure.writeRefused, .stale, .invalid] {
      #expect(failure.message == "\(failure.summary) \(failure.recovery)")
      #expect(!failure.summary.isEmpty)
      #expect(!failure.recovery.isEmpty)
    }
  }
}

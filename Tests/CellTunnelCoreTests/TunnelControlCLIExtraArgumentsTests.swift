//
//  TunnelControlCLIExtraArgumentsTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-29.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

// MARK: - TunnelControlCLIExtraArgumentsTests

/// Covers what a command does with arguments it takes no meaning from.
///
/// Ignoring them turns a typed flag into permission to proceed, which is how asking
/// `reset` what it does performed the reset instead of printing help.
@Suite("Control commands refuse arguments they cannot use")
struct TunnelControlCLIExtraArgumentsTests {
  @Test("reset with a trailing flag is refused rather than performed")
  func resetWithTrailingFlagIsRefused() {
    #expect(throws: TunnelDaemonError.self) {
      _ = try TunnelControlCLIAction.parse(arguments: ["reset", "--help"])
    }
  }

  @Test("stop with a trailing flag is refused")
  func stopWithTrailingFlagIsRefused() {
    #expect(throws: TunnelDaemonError.self) {
      _ = try TunnelControlCLIAction.parse(arguments: ["stop", "--dry-run"])
    }
  }

  @Test("status with a trailing argument is refused")
  func statusWithTrailingArgumentIsRefused() {
    #expect(throws: TunnelDaemonError.self) {
      _ = try TunnelControlCLIAction.parse(arguments: ["status", "extra"])
    }
  }

  /// The commands that legitimately take no arguments must still parse without them.
  @Test("argument-free commands still parse on their own")
  func argumentFreeCommandsStillParse() throws {
    #expect(try TunnelControlCLIAction.parse(arguments: ["status"]) == .status)
    #expect(try TunnelControlCLIAction.parse(arguments: ["check"]) == .check)
    #expect(try TunnelControlCLIAction.parse(arguments: ["peers"]) == .peers)
    #expect(try TunnelControlCLIAction.parse(arguments: ["stop"]) == .stop)
    #expect(try TunnelControlCLIAction.parse(arguments: ["reset"]) == .reset)
    #expect(try TunnelControlCLIAction.parse(arguments: ["start-discovery"]) == .startDiscovery)
    #expect(try TunnelControlCLIAction.parse(arguments: ["stop-discovery"]) == .stopDiscovery)
  }

  /// Commands that do take arguments must keep accepting them.
  @Test("a command that takes an argument still accepts it")
  func commandTakingAnArgumentStillAccepts() throws {
    let action = try TunnelControlCLIAction.parse(arguments: ["select", "2"])
    #expect(action == .select(reference: "2"))
  }
}

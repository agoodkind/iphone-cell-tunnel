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

// MARK: - TunnelControlCLIHelpRequestTests

/// Covers which argument vectors ask for help rather than for an action.
@Suite("Asking for help is recognised")
struct TunnelControlCLIHelpRequestTests {
  /// A person who types the obvious word gets help, not an unknown-command error.
  @Test("the bare word asks for help")
  func bareWordAsksForHelp() {
    #expect(isHelpRequest(arguments: ["help"]))
  }

  @Test("either flag asks for help from any position")
  func eitherFlagAsksForHelpAnywhere() {
    #expect(isHelpRequest(arguments: ["--help"]))
    #expect(isHelpRequest(arguments: ["-h"]))
    #expect(isHelpRequest(arguments: ["reset", "--help"]))
    #expect(isHelpRequest(arguments: ["configs", "import", "-h"]))
  }

  /// A configuration can be named `help`, so the word counts only as the command
  /// itself. Treating it as help anywhere would make that configuration unreachable.
  @Test("the word later in the arguments is a value, not a request for help")
  func wordLaterIsAValue() {
    #expect(!isHelpRequest(arguments: ["configs", "rename", "1", "help"]))
    #expect(!isHelpRequest(arguments: ["select", "help"]))
  }

  @Test("an ordinary command asks for nothing")
  func ordinaryCommandAsksForNothing() {
    #expect(!isHelpRequest(arguments: ["status"]))
    #expect(!isHelpRequest(arguments: []))
  }
}

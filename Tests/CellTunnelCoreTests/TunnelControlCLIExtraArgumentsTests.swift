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
  /// Asking `reset` what it does prints help rather than removing the saved profile.
  @Test("reset with a help flag asks for help rather than resetting")
  func resetWithHelpFlagAsksForHelp() throws {
    #expect(try TunnelControlCLIAction.parse(arguments: ["reset", "--help"]) == .help)
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

/// Covers which argument vectors ask for help rather than for an action, driven through
/// the parser the command-line tool actually calls.
@Suite("Asking for help is recognised")
struct TunnelControlCLIHelpRequestTests {
  /// A person who types the obvious word gets help, not an unknown-command error.
  @Test("the bare word parses as help")
  func bareWordParsesAsHelp() throws {
    #expect(try TunnelControlCLIAction.parse(arguments: ["help"]) == .help)
  }

  @Test("either flag parses as help from any position")
  func eitherFlagParsesAsHelpAnywhere() throws {
    #expect(try TunnelControlCLIAction.parse(arguments: ["--help"]) == .help)
    #expect(try TunnelControlCLIAction.parse(arguments: ["-h"]) == .help)
    #expect(try TunnelControlCLIAction.parse(arguments: ["reset", "--help"]) == .help)
    #expect(try TunnelControlCLIAction.parse(arguments: ["configs", "import", "-h"]) == .help)
  }

  /// A configuration can be named `help`, so the word counts only as the command
  /// itself. Treating it as help anywhere would make that configuration unreachable.
  @Test("the word later in the arguments stays a value")
  func wordLaterStaysAValue() throws {
    let action = try TunnelControlCLIAction.parse(arguments: ["select", "help"])
    #expect(action == .select(reference: "help"))
  }

  @Test("an ordinary command does not parse as help")
  func ordinaryCommandDoesNotParseAsHelp() throws {
    #expect(try TunnelControlCLIAction.parse(arguments: ["status"]) == .status)
  }

  /// The text a person reads has to reach them through the same path every other
  /// command's output takes, so the tool prints it without a branch of its own.
  @Test("running the help action returns the usage text")
  func helpActionReturnsUsage() async throws {
    let executor = TunnelControlCLIExecutor(client: SmokeTunnelControlClient())
    let output = try await executor.run(action: .help)

    #expect(output == tunnelControlUsageText)
    #expect(output.contains("usage: celltunnelctl <command> [options]"))
    #expect(output.contains("help, --help, -h"))
  }
}

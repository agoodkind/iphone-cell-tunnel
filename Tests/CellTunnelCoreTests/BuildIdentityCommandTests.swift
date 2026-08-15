//
//  BuildIdentityCommandTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-15.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

// MARK: - BuildIdentityCommandTests

/// Covers the command a person and the release smoke check both run to ask which build
/// this is, driven through the parser and the executor the tool itself calls.
///
/// The release smoke downloads the published artifact, runs it with `version`, and
/// requires the output to contain the word `version:` and the release tag. A change
/// that renamed the command, dropped the label, or omitted the version would publish an
/// artifact the pipeline then rejects, so these assert the printed shape rather than any
/// particular version value.
@Suite("Asking which build this is")
struct BuildIdentityCommandTests {
  @Test("the word parses as the version action")
  func wordParsesAsVersionAction() throws {
    #expect(try TunnelControlCLIAction.parse(arguments: ["version"]) == .version)
  }

  /// Trailing arguments are refused for the same reason every other argument-free
  /// command refuses them: ignoring them turns a typed flag into permission to proceed.
  @Test("a trailing argument is refused")
  func trailingArgumentIsRefused() {
    #expect(throws: TunnelDaemonError.self) {
      _ = try TunnelControlCLIAction.parse(arguments: ["version", "extra"])
    }
  }

  @Test("running the action prints the labelled version")
  func runningTheActionPrintsTheLabelledVersion() async throws {
    let executor = TunnelControlCLIExecutor(client: SmokeTunnelControlClient())

    let output = try await executor.run(action: .version)

    #expect(output.hasPrefix("version: "))
    #expect(output.contains(BuildIdentity.version))
    #expect(output.contains(BuildIdentity.commit))
  }

  /// A published build names itself by its release tag, and every other build names
  /// itself by what git describes, so neither ever reports an empty version.
  @Test("the version is never empty")
  func versionIsNeverEmpty() {
    #expect(!BuildIdentity.version.isEmpty)
  }

  /// The usage text lists the command, so a person who asks what the tool does can find
  /// it without reading the parser.
  @Test("the usage text lists the command")
  func usageTextListsTheCommand() {
    #expect(tunnelControlUsageText.contains("version"))
  }
}

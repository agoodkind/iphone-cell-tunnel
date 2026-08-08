//
//  GuestHarnessContractTests.swift
//  CellTunnelDevTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import CellTunnelDev

// MARK: - GuestHarnessContractTests

/// The decisions the harness makes before it touches the Mac it was pointed at: how it
/// reads its arguments, and what the launch agent it writes actually asks launchd to run.
struct GuestHarnessContractTests {
  // MARK: - Arguments

  @Test func optionsDefaultToADebugRunAsTheStandardUser() throws {
    let options = try parseGuestHarnessOptions(["192.168.64.2"])

    #expect(options.host == "192.168.64.2")
    #expect(options.configuration == "Debug")
    #expect(options.user == guestDefaultUser)
    #expect(options.pairTimeoutSeconds > 0)
    #expect(options.browseTimeoutSeconds > 0)
  }

  @Test func optionsReadTheConfigurationUserAndTimeouts() throws {
    let options = try parseGuestHarnessOptions([
      "mac-mini.local", "Release", "--user", "tester",
      "--pair-timeout", "45", "--browse-timeout", "9",
    ])

    #expect(options.configuration == "Release")
    #expect(options.user == "tester")
    #expect(options.pairTimeoutSeconds == 45)
    #expect(options.browseTimeoutSeconds == 9)
  }

  @Test func optionsRejectAMissingHost() {
    #expect(throws: ToolError.self) {
      try parseGuestHarnessOptions(["--user", "tester"])
    }
  }

  /// An option name is never a value. Taking one would dial a machine as a user called
  /// `--pair-timeout` and report an ssh failure, hiding the argument someone left out.
  @Test func optionsRejectAnOptionNameWhereAValueBelongs() {
    #expect(throws: ToolError.self) {
      try parseGuestHarnessOptions(["192.168.64.2", "--user", "--pair-timeout", "45"])
    }
  }

  // MARK: - Launch agent

  @Test func launchAgentRunsTheTransferredBinaryUnderTheRequestedServiceName() throws {
    let programPath = "/Users/admin/ict/Debug/CellTunnelAgent.app/Contents/MacOS/CellTunnelAgent"
    let label = "io.goodkind.celltunnel-agent"

    let rendered = guestLaunchAgentPlist(label: label, programPath: programPath)
    let plist = try PropertyListDecoder().decode(
      GuestLaunchAgentDefinition.self, from: Data(rendered.utf8))

    #expect(plist.label == label)
    #expect(plist.program == programPath)
    #expect(plist.machServices[label] == true)
    #expect(plist.keepAlive)
  }
}

// MARK: - GuestLaunchAgentDefinition

/// The launch agent as launchd reads it, so the test proves the rendered property list
/// parses and names the program by absolute path rather than matching its text.
private struct GuestLaunchAgentDefinition: Decodable {
  let keepAlive: Bool
  let label: String
  let machServices: [String: Bool]
  let program: String

  private enum CodingKeys: String, CodingKey {
    case keepAlive = "KeepAlive"
    case label = "Label"
    case machServices = "MachServices"
    case program = "Program"
  }
}

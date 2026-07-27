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

/// The three decisions the guest harness makes before it touches a guest: how it reads
/// its arguments, whether a build is signed well enough to run there, and what the
/// launch agent it writes actually asks launchd to run.
struct GuestHarnessContractTests {
  // MARK: - Arguments

  @Test func guestOptionsDefaultToADebugRunAgainstTheStandardBaseImage() throws {
    let options = try parseGuestHarnessOptions(["ict-live-check"])

    #expect(options.name == "ict-live-check")
    #expect(options.configuration == "Debug")
    #expect(options.baseImage == guestDefaultBaseImage)
    #expect(options.pairTimeoutSeconds > 0)
    #expect(options.browseTimeoutSeconds > 0)
  }

  @Test func guestOptionsReadTheConfigurationImageAndTimeouts() throws {
    let options = try parseGuestHarnessOptions([
      "ict-live-check", "Release", "--base-image", "other-image",
      "--pair-timeout", "45", "--browse-timeout", "9",
    ])

    #expect(options.configuration == "Release")
    #expect(options.baseImage == "other-image")
    #expect(options.pairTimeoutSeconds == 45)
    #expect(options.browseTimeoutSeconds == 9)
  }

  @Test func guestOptionsRejectAMissingName() {
    #expect(throws: ToolError.self) {
      try parseGuestHarnessOptions(["--base-image", "other-image"])
    }
  }

  // MARK: - Signing

  @Test func adHocSignatureReportsNoTeam() {
    // An ad-hoc bundle reaches the keychain nowhere, and this is the wording codesign
    // uses for it, so reading it as "no team" is what stops the run.
    let output = """
      Executable=/tmp/CellTunnelAgent.app/Contents/MacOS/CellTunnelAgent
      Identifier=io.goodkind.CellTunnel.Agent
      Signature=adhoc
      TeamIdentifier=not set
      """

    #expect(guestTeamIdentifier(in: output) == nil)
  }

  @Test func developmentSignatureReportsItsTeam() {
    let output = """
      Executable=/tmp/CellTunnelAgent.app/Contents/MacOS/CellTunnelAgent
      Identifier=io.goodkind.CellTunnel.Agent
      Authority=Apple Development: Alexander Goodkind
      TeamIdentifier=H3BMXM4W7H
      """

    #expect(guestTeamIdentifier(in: output) == "H3BMXM4W7H")
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

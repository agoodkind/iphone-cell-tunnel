//
//  GuestAgentService.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

// MARK: - Constants

private let guestAgentLogger = CellTunnelLog.logger(category: .build)
private let guestAgentRunningMarker = "state = running"
private let guestAgentCodeSigningMarker = "OS_REASON_CODESIGNING"
private let guestAgentReadyTimeoutSeconds: Double = 60
private let guestAgentPollIntervalSeconds: Double = 2

// MARK: - GuestAgentService

/// Namesake type so SwiftLint `file_name` matches `GuestAgentService.swift`.
enum GuestAgentService {}

/// Install the agent's launch agent and bring it up under launchd.
///
/// The agent registers a Mach service, so it has to run under launchd rather than by
/// opening the app: a directly opened app never registers the service, and every
/// later command then fails with repeated `agent xpc session open failed`. The plist
/// inside the bundle names its program with `BundleProgram`, which resolves only when
/// the app registers itself, so this writes a copy that names the binary by absolute
/// path and keeps the same service name, because that name is what the app looks up.
func startGuestAgent(shell: GuestShell, layout: GuestInstallLayout) throws {
  let userIdentifier = try shell.runRemote("id -u", describing: "reading the guest user id")
  let label = agentMachServiceName
  let launchAgentsDirectory = "/Users/\(shell.user)/Library/LaunchAgents"
  let plistPath = "\(launchAgentsDirectory)/\(label).plist"
  let localPlist = fileManager.temporaryDirectory.appendingPathComponent("\(label).plist")
  try guestLaunchAgentPlist(label: label, programPath: layout.agentBinaryPath)
    .write(to: localPlist, atomically: true, encoding: .utf8)

  try shell.runRemote(
    "mkdir -p '\(launchAgentsDirectory)'",
    describing: "creating the guest LaunchAgents directory"
  )
  try shell.copyIn([localPlist], to: plistPath)

  let serviceTarget = "gui/\(userIdentifier)/\(label)"
  // The guest has no dev tool of its own, so the load sequence runs as a script there.
  let script = """
    #!/usr/bin/env bash
    set -uo pipefail
    # A previous run may have left the service loaded; booting it out first is the only
    # way to replace its plist, and it is expected to fail when nothing is loaded.
    launchctl bootout '\(serviceTarget)' || true
    set -e
    launchctl bootstrap 'gui/\(userIdentifier)' '\(plistPath)'
    launchctl kickstart -k '\(serviceTarget)'
    """
  try shell.runScript(
    script,
    named: "bootstrap-agent",
    describing: "bootstrapping the agent launchd service"
  )

  try awaitGuestAgentRunning(shell: shell, serviceTarget: serviceTarget)
  try shell.runRemote(
    "'\(layout.controlToolPath)' status",
    describing: "asking the guest agent for its status"
  )
  guestAgentLogger.notice(
    "guest agent running target=\(serviceTarget, privacy: .public)")
  printToolOutput("guest: agent running as \(serviceTarget)")
}

/// Poll launchd until the service reports a running state, failing with the reason
/// launchd gave rather than a bare status.
private func awaitGuestAgentRunning(shell: GuestShell, serviceTarget: String) throws {
  guestAgentLogger.debug(
    "guest agent readiness poll starting target=\(serviceTarget, privacy: .public)")
  let deadline = Date().addingTimeInterval(guestAgentReadyTimeoutSeconds)
  var lastOutput = "launchd was never asked"
  while Date() < deadline {
    let result = try shell.captureRemote("launchctl print '\(serviceTarget)'")
    lastOutput = result.output
    if result.output.contains(guestAgentCodeSigningMarker) {
      throw ToolError.failure(
        """
        guest: the agent was killed at launch with \(guestAgentCodeSigningMarker), so its \
        entitlements are not authorized on this guest; the guest must boot with \
        amfi_get_out_of_my_way=1, which this run sets and verifies before installing
        """
      )
    }
    if result.status == 0, result.output.contains(guestAgentRunningMarker) {
      return
    }
    guestPollDelay(seconds: guestAgentPollIntervalSeconds)
  }
  throw ToolError.failure(
    """
    guest: \(serviceTarget) never reported `\(guestAgentRunningMarker)` within \
    \(Int(guestAgentReadyTimeoutSeconds))s; last `launchctl print` output: \
    \(guestOutputExcerpt(lastOutput))
    """
  )
}

/// The launch agent that runs the transferred agent binary by absolute path under the
/// Mach service name the app looks up.
func guestLaunchAgentPlist(label: String, programPath: String) -> String {
  """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>Label</key><string>\(label)</string>
    <key>Program</key><string>\(programPath)</string>
    <key>MachServices</key><dict><key>\(label)</key><true/></dict>
    <key>KeepAlive</key><true/>
  </dict>
  </plist>

  """
}

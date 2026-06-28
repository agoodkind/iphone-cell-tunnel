//
//  CleanReinstall.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

// MARK: - Constants

private let cleanReinstallLogger = CellTunnelLog.logger(category: .build)

// MARK: - clean-reinstall

/// Rebuilds and reinstalls both apps from a known-clean state in one command.
/// It stops any running agent, builds the Mac agent and the iPhone app, installs
/// and relaunches the agent so launchd runs the freshly built binary, removes the
/// saved Mac VPN configuration through that fresh agent, then reinstalls and
/// launches the iPhone app. The agent is installed and relaunched before
/// `reset-mac` runs, because removing the saved VPN configuration goes through a
/// live agent that understands the reset request.
func runCleanReinstall(_ command: String) throws {
  let configuration = try parseConfiguration(command: command)
  cleanReinstallLogger.notice(
    "clean-reinstall starting configuration=\(configuration, privacy: .public)"
  )

  printToolOutput("clean-reinstall: stopping any running agent")
  stopRunningAgentBestEffort()

  printToolOutput("clean-reinstall: building Mac agent and iPhone app")
  // Build both under one call so a decoupled clean-reinstall runs a single
  // GatedBuild.run that authorizes the Mac and iPhone compiles together.
  try buildProjects(targets: [.mac, .iphoneDevice], configuration: configuration)

  printToolOutput("clean-reinstall: installing and launching the agent")
  try runInstallMac(
    options: InstallMacOptions(
      configuration: configuration,
      explicitSourceAppPath: nil,
      destinationParentPath: defaultInstallParentDirectory
    )
  )

  printToolOutput("clean-reinstall: removing the saved Mac VPN configuration")
  try runResetMac([])

  printToolOutput("clean-reinstall: reinstalling the iPhone app")
  uninstallPhoneAppBestEffort()
  try installBuiltPhoneDevice(configuration: configuration)
  try launchInstalledPhoneDevice()

  printToolOutput("clean-reinstall: done")
}

// MARK: - Best-effort teardown

private func stopRunningAgentBestEffort() {
  let status = runBestEffort("killall", [agentBinaryName])
  cleanReinstallLogger.notice(
    "clean-reinstall agent stop status=\(status, privacy: .public)"
  )
}

private func uninstallPhoneAppBestEffort() {
  let deviceIdentifier: String
  do {
    deviceIdentifier = try selectedPhoneDeviceIdentifier()
  } catch {
    cleanReinstallLogger.notice(
      """
      clean-reinstall iphone uninstall skipped \
      reason=no-single-device details=\(error.localizedDescription, privacy: .public)
      """
    )
    return
  }
  let status = runBestEffort(
    "xcrun",
    [
      "devicectl",
      "device",
      "uninstall",
      "app",
      "--device",
      deviceIdentifier,
      phoneBundleIdentifier,
    ]
  )
  cleanReinstallLogger.notice(
    "clean-reinstall iphone uninstall status=\(status, privacy: .public)"
  )
}

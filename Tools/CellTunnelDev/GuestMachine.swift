//
//  GuestMachine.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let guestMachineLogger = CellTunnelLog.logger(category: .build)
private let guestAddressTimeoutSeconds: Double = 180
private let guestLoginTimeoutSeconds: Double = 300
private let guestShutdownTimeoutSeconds: Double = 180
private let guestPollIntervalSeconds: Double = 3
private let guestRunningState = "running"
private let guestBootArgument = "amfi_get_out_of_my_way=1"
private let guestDaemonUpMarkers = ["Permission denied", "publickey", "Too many authentication"]

let guestDefaultBaseImage = "ict-ui-test"
let guestDefaultUser = "admin"

// MARK: - GuestMachine

/// A guest that is running, reachable over one ssh connection, and booted with
/// entitlement enforcement off.
struct GuestMachine {
  let name: String
  let shell: GuestShell
}

// MARK: - TartVirtualMachine

struct TartVirtualMachine: Decodable {
  let name: String
  let state: String

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case state = "State"
  }
}

// MARK: - Preparation

/// Clone or reuse the named guest, start it, log in, and make sure it boots with
/// entitlement enforcement off. Every later step assumes all four.
func prepareGuestMachine(name: String, baseImage: String) throws -> GuestMachine {
  let tartLookup = try capture("which", ["tart"], echoOutput: false)
  guard tartLookup.status == 0 else {
    throw ToolError.failure(
      "guest: tart is required to run a guest; install it with `brew install cirruslabs/cli/tart`"
    )
  }

  try cloneGuestIfNeeded(name: name, baseImage: baseImage)
  try startGuestIfNeeded(name: name)
  let address = try awaitGuestAddress(name: name)
  printToolOutput("guest: \(name) answers at \(address)")
  var shell = try guestShell(address: address, user: guestDefaultUser)
  try awaitGuestLogin(shell: shell)
  shell = try ensureGuestBootArguments(name: name, shell: shell)
  return GuestMachine(name: name, shell: shell)
}

private func cloneGuestIfNeeded(name: String, baseImage: String) throws {
  let machines = try listGuestMachines()
  guard !machines.contains(where: { machine in machine.name == name }) else {
    printToolOutput("guest: reusing the existing \(name)")
    return
  }
  guard machines.contains(where: { machine in machine.name == baseImage }) else {
    throw ToolError.failure(
      """
      guest: no base image named \(baseImage) in `tart list`; pull or clone it first, \
      or name another image with --base-image
      """
    )
  }
  printToolOutput("guest: cloning \(baseImage) to \(name)")
  try run(
    "tart",
    ["clone", baseImage, name],
    failureMessage: "cloning the guest base image \(baseImage) to \(name)"
  )
}

private func startGuestIfNeeded(name: String) throws {
  let machines = try listGuestMachines()
  let running = machines.contains { machine in
    machine.name == name && machine.state == guestRunningState
  }
  guard !running else {
    printToolOutput("guest: \(name) is already running")
    return
  }

  let logDirectory = buildDirectory.appendingPathComponent("guest")
  try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
  let logURL = logDirectory.appendingPathComponent("\(name)-tart-run.log")
  fileManager.createFile(atPath: logURL.path, contents: nil)
  let logHandle = try FileHandle(forWritingTo: logURL)

  // `tart run` stays in the foreground for the life of the guest, so it is started
  // detached and outlives this command. Its console goes to a log file, which is
  // where a guest that never boots explains itself.
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["tart", "run", name, "--no-graphics"]
  process.currentDirectoryURL = repoRoot
  process.environment = mergedEnvironment([:])
  process.standardOutput = logHandle
  process.standardError = logHandle
  try process.run()
  guestMachineLogger.notice("guest started name=\(name, privacy: .public)")
  printToolOutput("guest: started \(name); console log at \(logURL.path)")
}

private func listGuestMachines() throws -> [TartVirtualMachine] {
  let result = try capture("tart", ["list", "--format", "json"], echoOutput: false)
  guard result.status == 0 else {
    throw ToolError.failure(
      """
      guest: `tart list --format json` failed with status \(result.status); \
      output: \(guestOutputExcerpt(result.output))
      """
    )
  }
  return try JSONDecoder().decode([TartVirtualMachine].self, from: Data(result.output.utf8))
}

// MARK: - Reachability

/// Poll `tart ip` until the guest reports an address. A guest answers this within
/// seconds of starting, well before its ssh daemon accepts connections.
private func awaitGuestAddress(name: String) throws -> String {
  let deadline = Date().addingTimeInterval(guestAddressTimeoutSeconds)
  var lastOutput = ""
  while Date() < deadline {
    let result = try capture("tart", ["ip", name], echoOutput: false)
    let candidate = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.status == 0, !candidate.isEmpty, !candidate.contains(" ") {
      return candidate
    }
    lastOutput = candidate
    guestPollDelay(seconds: guestPollIntervalSeconds)
  }
  throw ToolError.failure(
    """
    guest: \(name) reported no address within \(Int(guestAddressTimeoutSeconds))s; \
    last `tart ip` output: \(guestOutputExcerpt(lastOutput)); check the console log \
    under \(buildDirectory.appendingPathComponent("guest").path)
    """
  )
}

/// Wait for a working key login, installing the key exactly once along the way. The
/// key is installed only after the guest's ssh daemon has answered at least once,
/// because a password login attempted while the daemon is still starting is spent
/// for nothing and the guest counts it.
private func awaitGuestLogin(shell: GuestShell) throws {
  let deadline = Date().addingTimeInterval(guestLoginTimeoutSeconds)
  var installedKey = false
  var lastFailure = "no login attempted"
  while Date() < deadline {
    guard let failure = shell.loginFailure() else {
      printToolOutput("guest: key login works for \(shell.destination)")
      return
    }
    lastFailure = failure
    let daemonAnswered = guestDaemonUpMarkers.contains { marker in failure.contains(marker) }
    if daemonAnswered, !installedKey {
      try installGuestPublicKey(shell: shell)
      installedKey = true
      continue
    }
    guestPollDelay(seconds: guestPollIntervalSeconds)
  }
  throw ToolError.failure(
    """
    guest: no ssh login to \(shell.destination) within \(Int(guestLoginTimeoutSeconds))s; \
    last failure: \(lastFailure); the guest agent takes about half a minute after boot, \
    so a longer wait than that means the guest is not finishing its boot
    """
  )
}

private func awaitGuestUnreachable(shell: GuestShell) throws {
  let deadline = Date().addingTimeInterval(guestShutdownTimeoutSeconds)
  while Date() < deadline {
    if shell.loginFailure() != nil {
      return
    }
    guestPollDelay(seconds: guestPollIntervalSeconds)
  }
  throw ToolError.failure(
    """
    guest: \(shell.destination) still answers \(Int(guestShutdownTimeoutSeconds))s after \
    a reboot was requested, so the reboot did not take and the boot argument would not \
    be in effect
    """
  )
}

// MARK: - Boot arguments

/// Make sure the guest boots with entitlement enforcement off, rebooting it once if
/// it does not. A guest is not a registered device, so a development-signed agent is
/// killed at launch with `OS_REASON_CODESIGNING` without this argument. Setting it is
/// possible only because the base image already has System Integrity Protection off.
private func ensureGuestBootArguments(name: String, shell: GuestShell) throws -> GuestShell {
  if try guestBootArgumentPresent(shell: shell) {
    printToolOutput("guest: boot-args already carry \(guestBootArgument)")
    return shell
  }

  printToolOutput("guest: setting boot-args=\(guestBootArgument) and rebooting \(name)")
  try shell.runPrivileged(
    "nvram boot-args=\"\(guestBootArgument)\"",
    describing: "setting nvram boot-args",
    password: try guestPassword()
  )
  requestGuestReboot(shell: shell)
  shell.closeControlConnection()
  try awaitGuestUnreachable(shell: shell)

  let address = try awaitGuestAddress(name: name)
  let rebootedShell = try guestShell(address: address, user: shell.user)
  try awaitGuestLogin(shell: rebootedShell)
  guard try guestBootArgumentPresent(shell: rebootedShell) else {
    throw ToolError.failure(
      """
      guest: \(name) still reports no \(guestBootArgument) in `nvram boot-args` after a \
      reboot; without it a development-signed agent is killed at launch with \
      OS_REASON_CODESIGNING, and setting it needs System Integrity Protection off in the \
      base image
      """
    )
  }
  printToolOutput("guest: \(name) rebooted with \(guestBootArgument)")
  return rebootedShell
}

/// Ask the guest to reboot. The reboot drops this connection, so the command's own
/// status says nothing about whether it worked; the proof is the guest going away,
/// coming back, and then reporting the boot argument.
private func requestGuestReboot(shell: GuestShell) {
  do {
    let result = try shell.capturePrivileged("shutdown -r now", password: guestPassword())
    guestMachineLogger.notice(
      "guest reboot requested status=\(result.status, privacy: .public)")
  } catch {
    guestMachineLogger.notice(
      """
      guest reboot request lost its connection \
      details=\(error.localizedDescription, privacy: .public) recovery=wait-for-reboot
      """
    )
  }
}

private func guestBootArgumentPresent(shell: GuestShell) throws -> Bool {
  let result = try shell.captureRemote("nvram boot-args")
  // `nvram` exits nonzero when the variable was never set, which is the normal state
  // of a fresh clone rather than a failure to read it.
  guard result.status == 0 else {
    return false
  }
  return result.output.contains(guestBootArgument)
}

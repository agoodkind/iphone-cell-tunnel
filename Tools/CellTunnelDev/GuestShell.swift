//
//  GuestShell.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let guestShellLogger = CellTunnelLog.logger(category: .build)
private let guestConnectTimeoutSeconds = 10
private let guestControlPersistSeconds = 600
private let guestOutputExcerptLimit = 4_000
private let guestKeyType = "ed25519"
private let guestKeyComment = "cell-tunnel-guest"
private let guestKeyRelativePath = "~/.ssh/ict_guest"
private let guestSSHDirectoryPermissions = 0o700

/// A ControlMaster socket shared by every guest command in this run. ssh expands
/// `%r` and `%h`, so one path serves any guest without colliding between machines.
let guestControlPath = "/tmp/cell-tunnel-guest-%r@%h"

/// Where the guest keeps archives and scripts in flight. The guest home directory
/// stays free of transfer leftovers this way.
let guestRemoteScratchDirectory = "/tmp"

// MARK: - GuestShell

/// One reused ssh connection to the guest. Every guest command goes through here so
/// they share a single connection: the guest counts each new login, and repeated
/// password logins exhaust its authentication budget and then fail with `Too many
/// authentication failures`, which reads like a wrong password rather than a limit.
struct GuestShell {
  let address: String
  let user: String
  let identityFile: URL

  var destination: String {
    "\(user)@\(address)"
  }

  /// The ssh options every guest command carries. A throwaway known-hosts file keeps
  /// a re-cloned guest that reuses an address from failing host-key verification, and
  /// `BatchMode` turns a missing key into an immediate error instead of a prompt that
  /// hangs a non-interactive run.
  var connectionOptions: [String] {
    [
      "-o", "BatchMode=yes",
      "-o", "IdentitiesOnly=yes",
      "-i", identityFile.path,
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "LogLevel=ERROR",
      "-o", "ConnectTimeout=\(guestConnectTimeoutSeconds)",
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=\(guestControlPath)",
      "-o", "ControlPersist=\(guestControlPersistSeconds)",
    ]
  }

  func captureRemote(_ remoteCommand: String) throws -> CommandResult {
    try capture(
      "ssh",
      connectionOptions + [destination, remoteCommand],
      echoOutput: false
    )
  }

  /// Run a remote command and return its trimmed output, failing with the command,
  /// its status, and its output when it does not succeed.
  @discardableResult
  func runRemote(_ remoteCommand: String, describing description: String) throws -> String {
    let result = try captureRemote(remoteCommand)
    guard result.status == 0 else {
      throw ToolError.failure(
        """
        guest: \(description) failed on \(destination) with status \(result.status); \
        command: \(remoteCommand); output: \(guestOutputExcerpt(result.output))
        """
      )
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func copyIn(_ localPaths: [URL], to remoteDestination: String) throws {
    guard !localPaths.isEmpty else {
      throw ToolError.failure("guest: copy requested with no local paths")
    }
    let arguments =
      connectionOptions + localPaths.map(\.path) + ["\(destination):\(remoteDestination)"]
    let result = try capture("scp", arguments, echoOutput: false)
    guard result.status == 0 else {
      let names = localPaths.map(\.lastPathComponent).joined(separator: ", ")
      throw ToolError.failure(
        """
        guest: copying \(names) to \(destination):\(remoteDestination) failed with \
        status \(result.status); output: \(guestOutputExcerpt(result.output))
        """
      )
    }
  }

  /// Copy a multi-line script to the guest and run it there. Sending more than one
  /// command inline lets nested quoting through ssh rewrite the script and swallow
  /// its output, so the script travels as a file and only its path is quoted.
  @discardableResult
  func runScript(
    _ script: String,
    named name: String,
    describing description: String
  ) throws -> String {
    let localScript = fileManager.temporaryDirectory.appendingPathComponent("\(name).sh")
    try script.write(to: localScript, atomically: true, encoding: .utf8)
    defer { removeGuestTemporaryItem(at: localScript) }
    let remoteScript = "\(guestRemoteScratchDirectory)/\(name).sh"
    try copyIn([localScript], to: remoteScript)
    let output = try runRemote("bash '\(remoteScript)'", describing: description)
    let removalStatus = runBestEffort(
      "ssh", connectionOptions + [destination, "rm -f '\(remoteScript)'"])
    guestShellLogger.debug(
      """
      guest script cleanup name=\(name, privacy: .public) \
      status=\(removalStatus, privacy: .public)
      """
    )
    return output
  }

  /// Why a login is not working right now, or nil when the guest answers. The reason
  /// is kept rather than reduced to a Boolean so a waiting caller can report what the
  /// guest was actually saying when it gave up.
  func loginFailure() -> String? {
    do {
      let result = try captureRemote("true")
      if result.status == 0 {
        return nil
      }
      return "ssh exited \(result.status): \(guestOutputExcerpt(result.output))"
    } catch {
      return error.localizedDescription
    }
  }

}

// MARK: - Connection material

/// The guest shell for an address, creating the key pair on first use. This performs
/// no network work, so a caller can build the shell before the guest is up.
func guestShell(address: String, user: String) throws -> GuestShell {
  let identityFile = URL(
    fileURLWithPath: (guestKeyRelativePath as NSString).expandingTildeInPath)
  try createGuestKeyPairIfNeeded(identityFile: identityFile)
  return GuestShell(address: address, user: user, identityFile: identityFile)
}

private func createGuestKeyPairIfNeeded(identityFile: URL) throws {
  guard !fileManager.fileExists(atPath: identityFile.path) else {
    return
  }
  let sshDirectory = identityFile.deletingLastPathComponent()
  try fileManager.createDirectory(
    at: sshDirectory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: guestSSHDirectoryPermissions]
  )
  try run(
    "ssh-keygen",
    ["-t", guestKeyType, "-N", "", "-C", guestKeyComment, "-f", identityFile.path],
    failureMessage: "generating the guest ssh key at \(identityFile.path)"
  )
  printToolOutput("guest: generated \(identityFile.path)")
}

// MARK: - Process support

/// Block briefly without `sleep`, resuming off a dispatch queue, matching the
/// no-sleep delay pattern the relay polling uses.
func guestPollDelay(seconds: Double) {
  let semaphore = DispatchSemaphore(value: 0)
  DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
    semaphore.signal()
  }
  semaphore.wait()
}

/// A bounded, trimmed excerpt of command output, so a failure carries the verbatim
/// reason without pasting a whole log into one error.
func guestOutputExcerpt(_ text: String) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.count > guestOutputExcerptLimit else {
    return trimmed
  }
  return String(trimmed.suffix(guestOutputExcerptLimit))
}

/// The first whitespace-separated token of a command's output, used to read a digest
/// out of `shasum` output without a regular expression.
func guestFirstToken(_ text: String) -> String {
  text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
}

private func removeGuestTemporaryItem(at url: URL) {
  do {
    try fileManager.removeItem(at: url)
  } catch {
    guestShellLogger.debug(
      """
      guest temporary file cleanup failed path=\(url.lastPathComponent, privacy: .public) \
      details=\(error.localizedDescription, privacy: .public) recovery=continue
      """
    )
  }
}

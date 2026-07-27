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
private let guestPasswordEnvironmentKey = "CELL_TUNNEL_GUEST_PASSWORD"
private let sshpassPasswordEnvironmentKey = "SSHPASS"

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

  /// Run a command under `sudo` on the guest. The password travels on the command's
  /// standard input rather than in an argument or a file, so it never reaches the
  /// guest's process list or its disk.
  func capturePrivileged(_ remoteCommand: String, password: String) throws -> CommandResult {
    try captureWritingStandardInput(
      executable: "ssh",
      arguments: connectionOptions + [destination, "sudo -S -p '' \(remoteCommand)"],
      standardInput: Data((password + "\n").utf8)
    )
  }

  func runPrivileged(
    _ remoteCommand: String,
    describing description: String,
    password: String
  ) throws {
    let result = try capturePrivileged(remoteCommand, password: password)
    guard result.status == 0 else {
      throw ToolError.failure(
        """
        guest: \(description) failed under sudo on \(destination) with status \
        \(result.status); output: \(guestOutputExcerpt(result.output)); set \
        \(guestPasswordEnvironmentKey) when the guest account password is not the default
        """
      )
    }
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

  func closeControlConnection() {
    let status = runBestEffort("ssh", connectionOptions + ["-O", "exit", destination])
    guestShellLogger.debug(
      "guest control connection closed status=\(status, privacy: .public)")
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

/// Install the public key on the guest with the one password login this run is
/// allowed. The caller must have proven that key login does not already work, so a
/// reachable guest never spends an authentication attempt here.
func installGuestPublicKey(shell: GuestShell) throws {
  let publicKeyFile = URL(fileURLWithPath: shell.identityFile.path + ".pub")
  let publicKey = try String(contentsOf: publicKeyFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !publicKey.contains("'") else {
    throw ToolError.failure(
      "guest: \(publicKeyFile.path) contains a single quote and cannot be sent safely")
  }
  let sshpassLookup = try capture("which", ["sshpass"], echoOutput: false)
  guard sshpassLookup.status == 0 else {
    throw ToolError.failure(
      """
      guest: sshpass is needed once to install \(publicKeyFile.path) on \
      \(shell.destination); install it with `brew install sshpass`
      """
    )
  }
  let remoteCommand = """
    mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
    printf '%s\\n' '\(publicKey)' >> ~/.ssh/authorized_keys && \
    chmod 600 ~/.ssh/authorized_keys
    """
  // sshpass reads SSHPASS from the environment rather than an argument, so the
  // password never appears in this host's process list.
  let result = try capture(
    "sshpass",
    [
      "-e",
      "ssh",
      "-o", "PreferredAuthentications=password",
      "-o", "PubkeyAuthentication=no",
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "LogLevel=ERROR",
      "-o", "ConnectTimeout=\(guestConnectTimeoutSeconds)",
      shell.destination,
      remoteCommand,
    ],
    environment: [sshpassPasswordEnvironmentKey: try guestPassword()],
    echoOutput: false
  )
  guard result.status == 0 else {
    throw ToolError.failure(
      """
      guest: installing the ssh key on \(shell.destination) failed with status \
      \(result.status); output: \(guestOutputExcerpt(result.output)); a `Too many \
      authentication failures` message here means earlier password logins used up the \
      guest's attempts, so restart the guest before retrying
      """
    )
  }
  printToolOutput("guest: installed \(publicKeyFile.lastPathComponent) on \(shell.destination)")
}

/// The guest account password, read from the environment.
///
/// Not defaulted, because a default in source is a credential in the repository
/// even when the machine it opens is disposable, and a wrong default fails as an
/// authentication error that reads like a broken key rather than a missing
/// setting.
func guestPassword() throws -> String {
  let configured = ProcessInfo.processInfo.environment[guestPasswordEnvironmentKey]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let configured, !configured.isEmpty else {
    throw ToolError.usage(
      """
      \(guestPasswordEnvironmentKey) is not set. Export the guest account \
      password so the first login can install an ssh key.
      """)
  }
  return configured
}

// MARK: - Process support

/// Run a command with data on its standard input and return its status and merged
/// output. The input is written before the output is drained, which is safe only for
/// input small enough to fit the pipe buffer, and every caller here sends one line.
func captureWritingStandardInput(
  executable: String,
  arguments: [String],
  standardInput: Data
) throws -> CommandResult {
  guestShellLogger.debug(
    "captureWritingStandardInput executable=\(executable, privacy: .public)")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments
  process.currentDirectoryURL = repoRoot
  process.environment = mergedEnvironment([:])

  let inputPipe = Pipe()
  let outputPipe = Pipe()
  process.standardInput = inputPipe
  process.standardOutput = outputPipe
  process.standardError = outputPipe

  try process.run()
  try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
  try inputPipe.fileHandleForWriting.close()
  let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  let output = String(data: data, encoding: .utf8) ?? ""
  return CommandResult(status: process.terminationStatus, output: output)
}

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

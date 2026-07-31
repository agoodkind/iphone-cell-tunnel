//
//  GuestPairing.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let guestPairingLogger = CellTunnelLog.logger(category: .daemon)
private let guestPairingPollIntervalSeconds: Double = 2
private let guestPeerListingFirstEntryPrefix = "1)"
private let guestControlServiceType = "_cellrelaycontrol._tcp"
private let guestProviderBundleMarker = ".appex/Contents/MacOS/"
private let guestLSOFPathPrefix = "n"

// MARK: - GuestPairing

/// Namesake type so SwiftLint `file_name` matches `GuestPairing.swift`.
enum GuestPairing {}

// MARK: - GuestProviderVerdict

/// What the guest's running packet tunnel extension turned out to be.
enum GuestProviderVerdict {
  case matches(String)
  case mismatch(String)
  case notLoaded
}

// MARK: - Pairing

/// Start pairing on the Mac side and wait for the simulator to dial in.
///
/// Discovery is left running when this returns, because stopping it drops the peer a
/// validation run is about to use.
func awaitGuestPairing(
  shell: GuestShell,
  layout: GuestInstallLayout,
  timeoutSeconds: Double,
  browseTimeoutSeconds: Int
) throws -> String {
  try shell.runRemote(
    "'\(layout.controlToolPath)' start-discovery",
    describing: "starting relay discovery on the guest agent"
  )
  printToolOutput("guest: waiting up to \(Int(timeoutSeconds))s for the phone to dial in")

  let deadline = Date().addingTimeInterval(timeoutSeconds)
  var lastListing = "peers were never listed"
  while Date() < deadline {
    let result = try shell.captureRemote("'\(layout.controlToolPath)' peers")
    lastListing = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    // The listing numbers its entries from one, so a first line starting with `1)` is
    // the peer itself rather than the agent's no-peers wording.
    if result.status == 0, lastListing.hasPrefix(guestPeerListingFirstEntryPrefix) {
      guestPairingLogger.notice("guest pairing succeeded")
      return lastListing
    }
    guestPollDelay(seconds: guestPairingPollIntervalSeconds)
  }

  let browse = guestControlServiceBrowse(shell: shell, seconds: browseTimeoutSeconds)
  throw ToolError.failure(
    """
    guest: the phone never dialed in within \(Int(timeoutSeconds))s; the agent's last \
    peer listing was: \(lastListing); a \(browseTimeoutSeconds)s browse for \
    \(guestControlServiceType) on the guest saw: \(guestOutputExcerpt(browse)); an empty \
    browse alongside a listening agent means the guest never published the record, \
    which is the known headless-guest discovery limit rather than a defect in this build
    """
  )
}

/// Browse for the agent's control service on the guest. `dns-sd` runs until it is
/// killed without a timeout, and over a non-interactive session its output can be lost
/// entirely, which reads as an empty result rather than a browse that never finished,
/// so the timeout is always passed.
func guestControlServiceBrowse(shell: GuestShell, seconds: Int) -> String {
  do {
    // dns-sd exits nonzero when its own timeout ends the browse, so the output is the
    // result here and the status carries no information.
    let result = try shell.captureRemote(
      "dns-sd -t \(seconds) -B \(guestControlServiceType) local")
    return result.output
  } catch {
    return "the browse could not be run: \(error.localizedDescription)"
  }
}

// MARK: - Loaded provider

/// Decide whether the packet tunnel extension the guest is running came from the build
/// under test.
///
/// The system loads the provider from the saved profile's provider bundle identifier,
/// which resolves to a registered copy, while the agent runs from wherever its launch
/// agent points. Those two can come from different builds with nothing indicating it,
/// and the extension decides every packet-level behavior, so an observation that looks
/// like a defect in current source can be describing an installed build instead.
func guestProviderVerdict(
  shell: GuestShell,
  layout: GuestInstallLayout,
  expectedDigest: String
) throws -> GuestProviderVerdict {
  // `pgrep -x` matches the process name exactly, so the command sent over ssh cannot
  // match itself the way a full-command-line search would.
  let pgrepResult = try shell.captureRemote("pgrep -x \(guestProviderProcessName())")
  let pids = pgrepResult.output
    .split(whereSeparator: \.isWhitespace)
    .map(String.init)
  guestPairingLogger.notice(
    "guest tunnel provider processes found count=\(pids.count, privacy: .public)")
  guard !pids.isEmpty else {
    return .notLoaded
  }

  var mismatchReasons: [String] = []
  for pid in pids {
    let verdict = try guestProviderVerdictForProcess(
      shell: shell, layout: layout, expectedDigest: expectedDigest, pid: pid)
    switch verdict {
    case .matches:
      return verdict
    case .mismatch(let reason):
      mismatchReasons.append(reason)
    case .notLoaded:
      continue
    }
  }
  guard !mismatchReasons.isEmpty else {
    return .notLoaded
  }
  return .mismatch(mismatchReasons.joined(separator: "; "))
}

private func guestProviderVerdictForProcess(
  shell: GuestShell,
  layout: GuestInstallLayout,
  expectedDigest: String,
  pid: String
) throws -> GuestProviderVerdict {
  guard let runningPath = try guestProviderPath(shell: shell, pid: pid) else {
    return .mismatch(
      """
      the tunnel provider is running as pid \(pid) but neither its process entry nor its \
      open paths could be read, so which build it came from is unknown
      """
    )
  }
  guard runningPath.hasPrefix(layout.agentAppPath) else {
    return .mismatch(
      """
      the running tunnel provider is \(runningPath), which is not the copy this run \
      installed at \(layout.providerExecutablePath); the system loaded a registered \
      build, so nothing observed here describes the build under test
      """
    )
  }
  let digest = guestFirstToken(
    try shell.runRemote(
      "shasum -a 256 '\(runningPath)'",
      describing: "reading the checksum of the running tunnel provider"
    )
  )
  guard digest == expectedDigest else {
    return .mismatch(
      """
      the running tunnel provider at \(runningPath) has checksum \(digest) but the build \
      under test has \(expectedDigest), so the loaded extension is an older build
      """
    )
  }
  return .matches(runningPath)
}

/// The executable path of a running process, read from the process entry and from its
/// open paths. Both are asked because the process entry can be truncated and `lsof`
/// can be refused, and the answer names which one resolved.
private func guestProviderPath(shell: GuestShell, pid: String) throws -> String? {
  let processEntry = try shell.captureRemote("ps -p \(pid) -o comm=")
  let entryPath = processEntry.output.trimmingCharacters(in: .whitespacesAndNewlines)
  if processEntry.status == 0, entryPath.contains(guestProviderBundleMarker) {
    return entryPath
  }
  let openPaths = try shell.captureRemote("lsof -p \(pid) -a -d txt -Fn")
  for rawLine in openPaths.output.components(separatedBy: .newlines) {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix(guestLSOFPathPrefix) else {
      continue
    }
    let path = String(line.dropFirst(guestLSOFPathPrefix.count))
    if path.contains(guestProviderBundleMarker) {
      return path
    }
  }
  return nil
}

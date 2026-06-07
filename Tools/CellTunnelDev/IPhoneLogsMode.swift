//
//  IPhoneLogsMode.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let iPhoneLogsLogger = CellTunnelLog.logger(category: .build)
private let iPhoneLogsUsage = """
  usage: iphone-logs [--last <duration>] [--contains <text>] [--predicate <p>]
                     [--device <udid>] [--follow [--interval <seconds>]]

  Reads the attached iPhone's unified log for the io.goodkind.celltunnel
  subsystem, using Apple's `log collect` only (no third-party tooling). The
  unified log carries history, so it shows entries emitted before the command
  ran, including a one-time error that set lastError.

    --last        History range, in `log` duration form (default 5m).
    --contains    Only show lines whose message contains <text>.
    --predicate   Raw NSPredicate instead of the io.goodkind.celltunnel
                  subsystem default, to inspect system subsystems
                  (mDNSResponder, kernel, nesessionmanager). --contains still
                  ANDs onto it.
    --device      Collect from a specific device UDID. Defaults to the first
                  connected device.
    --follow      After the first dump, keep collecting on an interval and
                  print each new window, approximating a live stream. Runs
                  until Ctrl-C. Apple exposes no device log stream, so this
                  polls `log collect`.
    --interval    Seconds between --follow polls (default 3).

  `log collect` needs sudo; credentials cache so --follow does not re-prompt
  each poll within the sudo timeout.
  """
private let unifiedLogDefaultDuration = "5m"
private let unifiedLogArchiveName = "celltunnel-device.logarchive"
private let followDefaultIntervalSeconds: Double = 3
private let followWindowDuration = "10s"

// MARK: - Mode

/// One unified-log dump, or a repeating dump that approximates a live stream.
private enum IPhoneLogsMode {
  case follow(intervalSeconds: Double)
  case snapshot
}

// MARK: - Options

private struct IPhoneLogsOptions {
  var deviceOverride: String?
  var lastDuration = unifiedLogDefaultDuration
  var containsFilter: String?
  var rawPredicate: String?
  var follow = false
  var followIntervalSeconds = followDefaultIntervalSeconds
}

// MARK: - Entry point

func runIPhoneLogs(_ arguments: [String]) throws {
  var options = IPhoneLogsOptions()
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "--device":
      options.deviceOverride = try requireIPhoneLogsValue(&iterator, for: argument)
    case "--last":
      options.lastDuration = try requireIPhoneLogsValue(&iterator, for: argument)
    case "--contains":
      options.containsFilter = try requireIPhoneLogsValue(&iterator, for: argument)
    case "--predicate":
      options.rawPredicate = try requireIPhoneLogsValue(&iterator, for: argument)
    case "--follow":
      options.follow = true
    case "--interval":
      options.followIntervalSeconds = try requireIPhoneLogsInterval(&iterator, for: argument)
    case "-h", "--help":
      FileHandle.standardOutput.write(Data((iPhoneLogsUsage + "\n").utf8))
      return
    default:
      throw ToolError.usage("unknown iphone-logs argument: \(argument)")
    }
  }
  try dispatchIPhoneLogs(options)
}

private func dispatchIPhoneLogs(_ options: IPhoneLogsOptions) throws {
  let predicate = unifiedLogPredicate(
    containsFilter: options.containsFilter,
    rawPredicate: options.rawPredicate
  )
  let deviceUDID = resolvedDeviceUDID(override: options.deviceOverride)
  let mode: IPhoneLogsMode =
    options.follow ? .follow(intervalSeconds: options.followIntervalSeconds) : .snapshot

  try collectAndShowUnifiedLog(
    deviceUDID: deviceUDID,
    lastDuration: options.lastDuration,
    predicate: predicate
  )
  guard case .follow(let intervalSeconds) = mode else {
    return
  }
  while true {
    iPhoneLogsFollowDelay(seconds: intervalSeconds)
    try collectAndShowUnifiedLog(
      deviceUDID: deviceUDID,
      lastDuration: followWindowDuration,
      predicate: predicate
    )
  }
}

// MARK: - Unified-log collection

/// Collects the attached device's unified log into a temporary archive, then
/// prints the entries matching the predicate. `log collect` is the only device
/// log path Apple ships; it carries history, unlike a live attach. The predicate
/// filters the `log show` pass; `log collect` ignores it for an attached device.
private func collectAndShowUnifiedLog(
  deviceUDID: String?,
  lastDuration: String,
  predicate: String
) throws {
  iPhoneLogsLogger.notice(
    "iphone-logs collecting unified log lastDuration=\(lastDuration, privacy: .public)")
  let archiveURL = fileManager.temporaryDirectory.appendingPathComponent(unifiedLogArchiveName)
  if fileManager.fileExists(atPath: archiveURL.path) {
    try fileManager.removeItem(at: archiveURL)
  }
  defer {
    cleanupUnifiedLogArchive(at: archiveURL)
  }

  var collectArguments = ["log", "collect"]
  if let deviceUDID {
    collectArguments.append(contentsOf: ["--device-udid", deviceUDID])
  } else {
    collectArguments.append("--device")
  }
  collectArguments.append(contentsOf: [
    "--last", lastDuration,
    "--predicate", predicate,
    "--output", archiveURL.path,
  ])
  announceInvocation("sudo " + renderShellArguments(collectArguments))
  try run(
    "sudo",
    collectArguments,
    failureMessage: "sudo log collect failed (needs an admin password and a connected device)"
  )

  let showArguments = [
    "show", archiveURL.path,
    "--predicate", predicate,
    "--info", "--debug",
    "--style", "compact",
  ]
  announceInvocation("log " + renderShellArguments(showArguments))
  try run("log", showArguments)
}

private func unifiedLogPredicate(containsFilter: String?, rawPredicate: String?) -> String {
  var predicate = rawPredicate ?? "subsystem == \"\(CellTunnelLog.subsystem)\""
  if let containsFilter, !containsFilter.isEmpty {
    let escaped = containsFilter.replacingOccurrences(of: "\"", with: "\\\"")
    predicate += " AND composedMessage CONTAINS[c] \"\(escaped)\""
  }
  return predicate
}

private func cleanupUnifiedLogArchive(at archiveURL: URL) {
  guard fileManager.fileExists(atPath: archiveURL.path) else {
    return
  }
  do {
    try fileManager.removeItem(at: archiveURL)
  } catch {
    iPhoneLogsLogger.error(
      """
      iphone-logs temp archive cleanup failed \
      details=\(error.localizedDescription, privacy: .public) recovery=leave-archive
      """
    )
    FileHandle.standardError.write(
      Data("iphone-logs: failed to remove temp archive: \(error)\n".utf8))
  }
}

// MARK: - Device resolution

/// Resolves the device UDID for `log collect --device-udid` from an explicit
/// override or the environment, returning nil so the caller falls back to
/// `log collect --device` (first connected device) when none is set.
private func resolvedDeviceUDID(override: String?) -> String? {
  if let override, !override.isEmpty {
    return override
  }
  let environment = ProcessInfo.processInfo.environment
  for key in ["CELL_TUNNEL_IOS_DEVICE_UDID", "IOS_DEVICE_UDID"] {
    if let value = environment[key], !value.isEmpty {
      return value
    }
  }
  return nil
}

// MARK: - Follow delay

/// Waits the follow interval without a sleep call by signaling a semaphore from a
/// delayed dispatch, matching the no-sleep convention the repo enforces.
private func iPhoneLogsFollowDelay(seconds: Double) {
  let semaphore = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
    semaphore.signal()
  }
  semaphore.wait()
}

// MARK: - Rendering helpers

private func announceInvocation(_ rendered: String) {
  let banner = "iphone-logs: running: \(rendered)\n"
  FileHandle.standardError.write(Data(banner.utf8))
}

private func requireIPhoneLogsValue(
  _ iterator: inout IndexingIterator<[String]>,
  for option: String
) throws -> String {
  guard let value = iterator.next() else {
    throw ToolError.usage("missing value for \(option)")
  }
  return value
}

private func requireIPhoneLogsInterval(
  _ iterator: inout IndexingIterator<[String]>,
  for option: String
) throws -> Double {
  let raw = try requireIPhoneLogsValue(&iterator, for: option)
  guard let seconds = Double(raw), seconds > 0 else {
    throw ToolError.usage("\(option) must be a positive number of seconds")
  }
  return seconds
}

private func renderShellArguments(_ arguments: [String]) -> String {
  arguments.map(shellQuote).joined(separator: " ")
}

private func shellQuote(_ value: String) -> String {
  if value.allSatisfy({ character in
    character.isLetter || character.isNumber || character == "-" || character == "_"
      || character == "/" || character == "." || character == ":"
  }) {
    return value
  }
  let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
  return "'\(escaped)'"
}

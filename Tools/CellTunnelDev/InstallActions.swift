//
//  InstallActions.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

enum InstallActions {}

private let installLogger = CellTunnelLog.logger(category: .build)

let defaultInstallParentDirectory = "/Applications/CellTunnel"
private let installAppOptionName = "--app"
private let installConfigOptionName = "--config"
private let installDestinationOptionName = "--destination"
private let openExecutablePath = "/usr/bin/open"
private let installCommandArgumentDropCount = 2
private let installOptionPairStride = 2
private let agentLaunchVerifyAttempts = 10
private let agentLaunchVerifyDelaySeconds: Double = 1.0
private let agentExecutableSubpath = "Contents/MacOS"

// MARK: - InstallMacOptions

struct InstallMacOptions {
  let configuration: String
  let explicitSourceAppPath: String?
  let destinationParentPath: String
}

func parseInstallMacOptions() throws -> InstallMacOptions {
  let arguments = Array(CommandLine.arguments.dropFirst(installCommandArgumentDropCount))
  let usage = """
    usage: install-mac [\(installConfigOptionName) Debug|Release] \
    [\(installAppOptionName) <path>] [\(installDestinationOptionName) <dir>]
    """

  var configuration = "Debug"
  var explicitSourceAppPath: String?
  var destinationParentPath = defaultInstallParentDirectory

  var index = arguments.startIndex
  while index < arguments.endIndex {
    let argument = arguments[index]
    let valueIndex = arguments.index(after: index)
    switch argument {
    case installConfigOptionName:
      guard valueIndex < arguments.endIndex else {
        throw ToolError.usage("missing value for \(installConfigOptionName). \(usage)")
      }
      let value = arguments[valueIndex]
      guard value == "Debug" || value == "Release" else {
        throw ToolError.usage(
          "invalid \(installConfigOptionName) value: \(value). \(usage)")
      }
      configuration = value
      index = arguments.index(index, offsetBy: installOptionPairStride)
    case installAppOptionName:
      guard valueIndex < arguments.endIndex else {
        throw ToolError.usage("missing value for \(installAppOptionName). \(usage)")
      }
      explicitSourceAppPath = arguments[valueIndex]
      index = arguments.index(index, offsetBy: installOptionPairStride)
    case installDestinationOptionName:
      guard valueIndex < arguments.endIndex else {
        throw ToolError.usage(
          "missing value for \(installDestinationOptionName). \(usage)")
      }
      destinationParentPath = arguments[valueIndex]
      index = arguments.index(index, offsetBy: installOptionPairStride)
    default:
      throw ToolError.usage("unknown install-mac argument: \(argument). \(usage)")
    }
  }

  return InstallMacOptions(
    configuration: configuration,
    explicitSourceAppPath: explicitSourceAppPath,
    destinationParentPath: destinationParentPath
  )
}

func runInstallMac(options: InstallMacOptions) throws {
  let sourceAppURL = try resolveInstallMacSourceURL(options: options)
  installLogger.notice(
    "install-mac source resolved path=\(sourceAppURL.path, privacy: .public)"
  )
  printToolOutput("source: \(sourceAppURL.path)")

  let destinationParentURL = URL(
    fileURLWithPath: (options.destinationParentPath as NSString).expandingTildeInPath,
    isDirectory: true
  )
  try fileManager.createDirectory(at: destinationParentURL, withIntermediateDirectories: true)

  let destinationAppURL = destinationParentURL.appendingPathComponent(agentAppBundleName)
  if fileManager.fileExists(atPath: destinationAppURL.path) {
    try fileManager.removeItem(at: destinationAppURL)
  }
  try fileManager.copyItem(at: sourceAppURL, to: destinationAppURL)
  installLogger.notice(
    """
    install-mac copied bundle source=\(sourceAppURL.path, privacy: .public) \
    destination=\(destinationAppURL.path, privacy: .public)
    """
  )
  printToolOutput("installed: \(destinationAppURL.path)")

  try launchInstalledAgent(at: destinationAppURL)
  try verifyInstalledAgentRunning(installedAppURL: destinationAppURL)
  printToolOutput(
    """
    agent launched; approve 'CellTunnel' in System Settings > General > Login Items \
    if prompted, then run: celltunnelctl start --config <path>
    """
  )
}

private func resolveInstallMacSourceURL(options: InstallMacOptions) throws -> URL {
  if let explicit = options.explicitSourceAppPath {
    let trimmed = explicit.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      throw ToolError.usage("\(installAppOptionName) must not be empty")
    }
    let explicitURL = URL(
      fileURLWithPath: (trimmed as NSString).expandingTildeInPath
    )
    guard fileManager.fileExists(atPath: explicitURL.path) else {
      throw ToolError.failure(
        "install-mac: source bundle not found at \(explicitURL.path)")
    }
    return explicitURL
  }

  let defaultSource = xcodeConfigurationBuildDirectory(
    configuration: options.configuration,
    platformName: macOSPlatformName
  ).appendingPathComponent(agentAppBundleName)
  guard fileManager.fileExists(atPath: defaultSource.path) else {
    throw ToolError.failure(
      """
      install-mac: source bundle not found at \(defaultSource.path); \
      run `make build TARGET=mac CONFIG=\(options.configuration)` first
      """
    )
  }
  return defaultSource
}

private func launchInstalledAgent(at appURL: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: openExecutablePath)
  process.arguments = ["-a", appURL.path]
  try process.run()
  installLogger.notice(
    "install-mac launched agent path=\(appURL.path, privacy: .public)"
  )
}

/// Pair two optionals into a tuple only when both are non-nil, so a comparison of
/// the running agent's identity against the installed binary's is expressed as a
/// single-line `if`, which both swift-format and swiftlint accept.
private func bothPresent<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
  guard let first, let second else {
    return nil
  }
  return (first, second)
}

// MARK: - Agent launch verification

/// Confirm the freshly installed agent came up and is the binary just built. The
/// agent is an on-demand XPC service, so a successful `check()` both launches it and
/// proves it is reachable; comparing the reported Mach-O UUID and SHA-256 to the
/// installed binary catches a stale agent registered from another bundle path that
/// answers for an old build. A mismatch self-recovers once: a long-running stale
/// agent process can survive the stop step and keep the mach service, so the
/// verification kickstarts the launchd service, which kills that process and
/// relaunches from the registered bundle path (now holding the fresh binary), then
/// re-verifies before failing.
private func verifyInstalledAgentRunning(installedAppURL: URL) throws {
  installLogger.notice(
    "install-mac verifying agent path=\(installedAppURL.path, privacy: .public)"
  )
  let installedBinary =
    installedAppURL
    .appendingPathComponent(agentExecutableSubpath)
    .appendingPathComponent(agentBinaryName)
  if let mismatch = try runningAgentMismatch(installedBinary: installedBinary) {
    printToolOutput(
      "stale agent answered the check (\(mismatch)); restarting the launchd service")
    installLogger.notice(
      """
      install-mac stale agent answered \(mismatch, privacy: .public) \
      recovery=kickstart-and-reverify
      """
    )
    kickstartAgentService()
    if let persistent = try runningAgentMismatch(installedBinary: installedBinary) {
      throw ToolError.failure(
        """
        installed agent does not match the freshly built binary (\(persistent)) \
        after a launchd kickstart; a stale agent may be registered
        """
      )
    }
  }
  printToolOutput("agent verified up and matches the freshly built binary")
}

/// Compare the running agent's reported identity to the installed binary. Returns a
/// short mismatch description, or nil when the running agent is the installed build.
private func runningAgentMismatch(installedBinary: URL) throws -> String? {
  let report = try awaitAgentCheck()
  var reported: [String: String] = [:]
  for check in report.checks {
    reported[check.name] = check.value
  }
  let runningUUID = reported["agent_build_uuid"]
  let expectedUUID = machOUUID(of: installedBinary)
  let uuidMismatch =
    bothPresent(expectedUUID, runningUUID).map { expected, running in
      expected.caseInsensitiveCompare(running) != .orderedSame
    } ?? false
  if uuidMismatch {
    return "build uuid \(runningUUID ?? "") != \(expectedUUID ?? "")"
  }
  let runningSHA = reported["agent_executable_sha256"]
  let expectedSHA = fileSHA256(of: installedBinary)
  let shaMismatch = bothPresent(expectedSHA, runningSHA).map { $0 != $1 } ?? false
  if shaMismatch {
    return "sha256 mismatch"
  }
  installLogger.notice(
    "install-mac agent verified path=\(reported["agent_executable_path"] ?? "", privacy: .public)"
  )
  return nil
}

/// Restart the agent's launchd service in place. `kickstart -k` kills the running
/// process, and launchd relaunches it from the registered bundle path, so the next
/// XPC connect answers from the freshly installed binary. Best effort: when the
/// kickstart itself fails, the re-verification decides the outcome.
private func kickstartAgentService() {
  let serviceTarget = "gui/\(getuid())/\(agentMachServiceName)"
  let status = runBestEffort("launchctl", ["kickstart", "-k", serviceTarget])
  installLogger.notice(
    """
    install-mac kickstarted agent service target=\(serviceTarget, privacy: .public) \
    status=\(status, privacy: .public)
    """
  )
}

/// Poll the agent's `check()` a bounded number of times. The on-demand agent
/// launches on the first XPC connect, so an early attempt can fail before it is
/// ready. Throws a clear, actionable error when it never answers.
private func awaitAgentCheck() throws -> TunnelEnvironmentReport {
  var lastError: Error?
  for attempt in 1...agentLaunchVerifyAttempts {
    let box = AgentCheckBox()
    do {
      try runRelayCommand { client in
        box.store(try await client.check())
      }
      if let report = box.report() {
        return report
      }
      lastError = ToolError.failure("agent check returned no report")
    } catch {
      lastError = error
      installLogger.notice(
        """
        install-mac agent check attempt failed \
        details=\(error.localizedDescription, privacy: .public) recovery=retry
        """
      )
    }
    installLogger.notice(
      "install-mac agent check not ready attempt=\(attempt, privacy: .public)")
    agentLaunchVerifyDelay()
  }
  throw ToolError.failure(
    """
    agent did not come up after install; approve 'CellTunnel' in System Settings > \
    General > Login Items, then re-run (\(lastError?.localizedDescription ?? "no response"))
    """
  )
}

/// Block briefly without `sleep`, resuming off a dispatch queue, matching the
/// no-sleep delay pattern the relay polling uses.
private func agentLaunchVerifyDelay() {
  let semaphore = DispatchSemaphore(value: 0)
  DispatchQueue.global().asyncAfter(deadline: .now() + agentLaunchVerifyDelaySeconds) {
    semaphore.signal()
  }
  semaphore.wait()
}

/// The Mach-O `LC_UUID` of a binary read with `dwarfdump --uuid`, uppercased, or
/// nil when the file is absent or the read fails.
private func machOUUID(of binary: URL) -> String? {
  guard fileManager.fileExists(atPath: binary.path) else {
    return nil
  }
  let result: CommandResult
  do {
    result = try capture("dwarfdump", ["--uuid", binary.path], echoOutput: false)
  } catch {
    installLogger.error(
      "install-mac dwarfdump failed details=\(error.localizedDescription, privacy: .public)")
    return nil
  }
  guard result.status == 0 else {
    return nil
  }
  for token in result.output.split(whereSeparator: \.isWhitespace) {
    let candidate = String(token)
    if UUID(uuidString: candidate) != nil {
      return candidate.uppercased()
    }
  }
  return nil
}

/// The SHA-256 of a file via `shasum -a 256`, or nil when absent or on failure.
private func fileSHA256(of binary: URL) -> String? {
  guard fileManager.fileExists(atPath: binary.path) else {
    return nil
  }
  let result: CommandResult
  do {
    result = try capture("shasum", ["-a", "256", binary.path], echoOutput: false)
  } catch {
    installLogger.error(
      "install-mac shasum failed details=\(error.localizedDescription, privacy: .public)")
    return nil
  }
  guard result.status == 0 else {
    return nil
  }
  return result.output.split(whereSeparator: \.isWhitespace).first.map(String.init)
}

// MARK: - AgentCheckBox

/// Thread-safe carrier for the agent report produced inside the bridged async task,
/// so the synchronous caller reads it after `runRelayCommand` returns.
private final class AgentCheckBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TunnelEnvironmentReport?

  func store(_ report: TunnelEnvironmentReport) {
    lock.lock()
    defer { lock.unlock() }
    value = report
  }

  func report() -> TunnelEnvironmentReport? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

//
//  GuestHarness.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let guestHarnessLogger = CellTunnelLog.logger(category: .build)
private let guestBaseImageOptionName = "--base-image"
private let guestPairTimeoutOptionName = "--pair-timeout"
private let guestBrowseTimeoutOptionName = "--browse-timeout"
private let guestPairTimeoutDefaultSeconds: Double = 180
private let guestBrowseTimeoutDefaultSeconds = 12
private let guestOptionStride = 2

let guestCommandUsage = """
  usage: guest <guest-name> [Debug|Release] [\(guestBaseImageOptionName) <image>] \
  [\(guestPairTimeoutOptionName) <seconds>] [\(guestBrowseTimeoutOptionName) <seconds>]
  """

// MARK: - GuestHarness

/// Namesake type so SwiftLint `file_name` matches `GuestHarness.swift`.
enum GuestHarness {}

// MARK: - GuestHarnessOptions

struct GuestHarnessOptions {
  let name: String
  let configuration: String
  let baseImage: String
  let pairTimeoutSeconds: Double
  let browseTimeoutSeconds: Int
}

// MARK: - Command

/// Run the whole guest validation in one command: build every target signed, verify
/// each signature, clone or reuse the guest, transfer the products, run the agent
/// under launchd, launch the phone app in a guest simulator, wait for the two to pair,
/// and report what the guest is actually running.
func runGuestHarness(_ arguments: [String]) throws {
  let options = try parseGuestHarnessOptions(arguments)
  guestHarnessLogger.notice(
    """
    guest harness starting name=\(options.name, privacy: .public) \
    configuration=\(options.configuration, privacy: .public)
    """
  )

  let team = try applyGuestSigningEnvironment()
  printToolOutput(
    """
    guest: building mac, mac-catalyst and iphone-simulator (\(options.configuration)) \
    signed for team \(team)
    """
  )
  try buildGuestProducts(configuration: options.configuration)

  let products = guestProducts(configuration: options.configuration)
  try verifyGuestProductSignatures(products, expectedTeam: team)
  let providerExecutable = try guestProviderExecutable(configuration: options.configuration)
  let providerDigest = try guestFileDigest(at: providerExecutable)

  let machine = try prepareGuestMachine(name: options.name, baseImage: options.baseImage)
  let layout = try transferGuestProducts(
    products: products, shell: machine.shell, configuration: options.configuration)
  try startGuestAgent(shell: machine.shell, layout: layout)
  let simulator = try launchGuestPhoneApp(shell: machine.shell, layout: layout)
  let peers = try awaitGuestPairing(
    shell: machine.shell,
    layout: layout,
    timeoutSeconds: options.pairTimeoutSeconds,
    browseTimeoutSeconds: options.browseTimeoutSeconds
  )
  let verdict = try guestProviderVerdict(
    shell: machine.shell, layout: layout, expectedDigest: providerDigest)

  try reportGuestResult(
    machine: machine,
    layout: layout,
    simulator: simulator,
    peers: peers,
    verdict: verdict
  )
}

// MARK: - Result

/// Print what the run established, and refuse to call it a result when the extension
/// the guest is running did not come from this build.
private func reportGuestResult(
  machine: GuestMachine,
  layout: GuestInstallLayout,
  simulator: String,
  peers: String,
  verdict: GuestProviderVerdict
) throws {
  printToolOutput(
    """
    guest \(machine.name) at \(machine.shell.address)
      root       \(layout.root)
      agent      \(layout.agentAppPath)
      catalyst   \(layout.catalystAppPath)
      simulator  \(layout.simulatorAppPath) on \(simulator)
      control    \(layout.controlToolPath)
      paired     \(peers)
    """
  )
  switch verdict {
  case .matches(let path):
    printToolOutput(
      """
      guest: paired, and the loaded tunnel provider at \(path) is the build under test, \
      so packet-level behavior observed from here describes this build
      """
    )
  case .mismatch(let reason):
    throw ToolError.failure(
      """
      guest: paired, but the run cannot report a result: \(reason). Remove the saved VPN \
      profile with `celltunnelctl reset` on the guest, then run this command again so the \
      system loads the provider this run installed.
      """
    )
  case .notLoaded:
    printToolOutput(
      """
      guest: paired, and no tunnel is up, so no packet tunnel extension is loaded yet. \
      Nothing packet-level has been observed, and any later observation is about this \
      build only while the loaded provider stays \(layout.providerExecutablePath).
      """
    )
  }
}

// MARK: - Argument parsing

func parseGuestHarnessOptions(_ arguments: [String]) throws -> GuestHarnessOptions {
  guard let name = arguments.first, !name.hasPrefix("-") else {
    throw ToolError.usage(guestCommandUsage)
  }

  var configuration = "Debug"
  var baseImage = guestDefaultBaseImage
  var pairTimeoutSeconds = guestPairTimeoutDefaultSeconds
  var browseTimeoutSeconds = guestBrowseTimeoutDefaultSeconds

  var index = arguments.index(after: arguments.startIndex)
  while index < arguments.endIndex {
    let argument = arguments[index]
    switch argument {
    case "Debug", "Release":
      configuration = argument
      index = arguments.index(after: index)
    case guestBaseImageOptionName:
      baseImage = try guestOptionValue(arguments, after: index, optionName: argument)
      index = arguments.index(index, offsetBy: guestOptionStride)
    case guestPairTimeoutOptionName:
      pairTimeoutSeconds = try guestTimeoutValue(arguments, after: index, optionName: argument)
      index = arguments.index(index, offsetBy: guestOptionStride)
    case guestBrowseTimeoutOptionName:
      let seconds = try guestTimeoutValue(arguments, after: index, optionName: argument)
      browseTimeoutSeconds = Int(seconds)
      index = arguments.index(index, offsetBy: guestOptionStride)
    default:
      throw ToolError.usage("guest: unknown argument \(argument). \(guestCommandUsage)")
    }
  }

  return GuestHarnessOptions(
    name: name,
    configuration: configuration,
    baseImage: baseImage,
    pairTimeoutSeconds: pairTimeoutSeconds,
    browseTimeoutSeconds: browseTimeoutSeconds
  )
}

private func guestOptionValue(
  _ arguments: [String],
  after index: Int,
  optionName: String
) throws -> String {
  let valueIndex = arguments.index(after: index)
  guard valueIndex < arguments.endIndex else {
    throw ToolError.usage("guest: missing value for \(optionName). \(guestCommandUsage)")
  }
  let value = arguments[valueIndex]
  guard !value.isEmpty else {
    throw ToolError.usage("guest: \(optionName) must not be empty. \(guestCommandUsage)")
  }
  return value
}

private func guestTimeoutValue(
  _ arguments: [String],
  after index: Int,
  optionName: String
) throws -> Double {
  let raw = try guestOptionValue(arguments, after: index, optionName: optionName)
  guard let seconds = Double(raw), seconds > 0 else {
    throw ToolError.usage("guest: \(optionName) must be a positive number of seconds")
  }
  return seconds
}

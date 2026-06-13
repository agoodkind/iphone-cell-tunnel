//
//  ActivationActions.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation

private let keyValuePairComponentCount = 2
private let simulatorNameSuffixLength = 8

enum ActivationActions {}

func activateTarget(
  _ target: ActivationTarget,
  configuration: String,
  listenerPort: UInt16? = nil
) throws {
  switch target {
  case .iphone:
    try activatePhoneDevice(configuration: configuration, listenerPort: listenerPort)
  case .iphoneSimulator:
    try activatePhoneSimulator(configuration: configuration, listenerPort: listenerPort)
  case .macCatalyst:
    try activateMacCatalyst(configuration: configuration, listenerPort: listenerPort)
  }
}

func activatePhoneDevice(configuration: String, listenerPort: UInt16? = nil) throws {
  try installBuiltPhoneDevice(configuration: configuration)
  try launchInstalledPhoneDevice(listenerPort: listenerPort)
}

func activatePhoneSimulator(configuration: String, listenerPort: UInt16? = nil) throws {
  let simulatorIdentifier = try selectedPhoneSimulatorIdentifier()
  let appPath = phoneSimulatorAppPath(configuration: configuration)
  guard fileManager.fileExists(atPath: appPath.path) else {
    throw ToolError.failure("built phone simulator app not found: \(appPath.path)")
  }

  try bootPhoneSimulator(identifier: simulatorIdentifier)
  try run("xcrun", ["simctl", "install", simulatorIdentifier, appPath.path])
  var launchArguments = [
    "simctl",
    "launch",
    "--terminate-running-process",
    simulatorIdentifier,
    phoneBundleIdentifier,
    phoneActivationArgument,
  ]
  launchArguments.append(contentsOf: phoneListenerPortLaunchArguments(listenerPort))
  try run("xcrun", launchArguments)
}

func phoneSimulatorAppPath(configuration: String) -> URL {
  xcodeConfigurationBuildDirectory(
    configuration: configuration,
    platformName: iOSSimulatorPlatformName
  ).appendingPathComponent("CellTunnelPhone.app")
}

/// Build-products launch of the Mac Catalyst UI app, symmetric with the iPhone
/// activation paths. The app must already be built (`make run` builds before it
/// activates); a missing bundle is a clear error rather than a silent fallback. Any
/// running instance is terminated first so the freshly built binary runs, the Mac
/// equivalent of the `--terminate-existing` launch the device and simulator paths
/// use, then the bundle is opened through LaunchServices. The activation and
/// listener-port arguments are inert on Catalyst and are forwarded only for symmetry.
func activateMacCatalyst(configuration: String, listenerPort: UInt16? = nil) throws {
  let appPath = macCatalystAppPath(configuration: configuration)
  guard fileManager.fileExists(atPath: appPath.path) else {
    throw ToolError.failure("built Mac Catalyst app not found: \(appPath.path)")
  }
  printToolOutput("launching: \(appPath.path)")
  _ = runBestEffort("pkill", ["-x", "CellTunnelPhone"])
  var openArguments = [appPath.path, "--args", phoneActivationArgument]
  openArguments.append(contentsOf: phoneListenerPortLaunchArguments(listenerPort))
  try run("open", openArguments)
}

/// The Mac Catalyst product bundle, resolved through `xcodeConfigurationBuildDirectory`
/// so it lands at the signed `Products/Debug-maccatalyst` location every build writes
/// to, never the unsigned dead-code copy under `build/`.
func macCatalystAppPath(configuration: String) -> URL {
  xcodeConfigurationBuildDirectory(
    configuration: configuration,
    platformName: macCatalystPlatformName
  ).appendingPathComponent("CellTunnelPhone.app")
}

// MARK: - SimulatorDeviceList

struct SimulatorDeviceList: Decodable {
  let devices: [String: [SimulatorDevice]]
}

// MARK: - SimulatorDevice

struct SimulatorDevice: Decodable {
  let udid: String
  let isAvailable: Bool
  let deviceTypeIdentifier: String
  let lastBootedAt: String?
  let name: String
  let state: String
}

// MARK: - SimulatorRuntimeList

struct SimulatorRuntimeList: Decodable {
  let runtimes: [SimulatorRuntime]
}

// MARK: - SimulatorRuntime

struct SimulatorRuntime: Decodable {
  let identifier: String
  let isAvailable: Bool
  let name: String
  let supportedDeviceTypes: [SimulatorSupportedDeviceType]
  let version: String
}

// MARK: - SimulatorSupportedDeviceType

struct SimulatorSupportedDeviceType: Decodable {
  let identifier: String
  let name: String
  let productFamily: String
}

// MARK: - AvailableSimulator

struct AvailableSimulator {
  let runtimeIdentifier: String
  let device: SimulatorDevice
}

func phoneDeviceAppPath(configuration: String) -> URL {
  xcodeConfigurationBuildDirectory(
    configuration: configuration,
    platformName: iOSDevicePlatformName
  ).appendingPathComponent("CellTunnelPhone.app")
}

func launchInstalledPhoneDevice(listenerPort: UInt16? = nil) throws {
  let deviceIdentifier = try selectedPhoneDeviceIdentifier()
  var launchArguments = [
    "devicectl",
    "device",
    "process",
    "launch",
    "--terminate-existing",
    "--device",
    deviceIdentifier,
    phoneBundleIdentifier,
    phoneActivationArgument,
  ]
  launchArguments.append(contentsOf: phoneListenerPortLaunchArguments(listenerPort))
  try run("xcrun", launchArguments)
}

func phoneListenerPortLaunchArguments(_ listenerPort: UInt16?) -> [String] {
  guard let listenerPort else {
    return []
  }
  return [phoneListenerPortArgument, String(listenerPort)]
}

func selectedPhoneSimulatorIdentifier() throws -> String {
  let environment = ProcessInfo.processInfo.environment
  if let simulatorIdentifier = environment["IOS_SIMULATOR_ID"], !simulatorIdentifier.isEmpty {
    return simulatorIdentifier
  }
  if let destination = environment["IOS_SIMULATOR_DESTINATION"], !destination.isEmpty {
    if let simulatorIdentifier = try simulatorIdentifier(from: destination) {
      return simulatorIdentifier
    }
  }

  let bootedSimulators = try availablePhoneSimulators().filter { simulator in
    simulator.device.state == "Booted"
  }
  if let simulator = preferredSimulator(from: bootedSimulators) {
    return simulator.device.udid
  }

  return try createPhoneSimulator()
}

func simulatorIdentifier(from destination: String) throws -> String? {
  var components: [String: String] = [:]
  for part in destination.split(separator: ",") {
    let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
    let pieces = trimmedPart.split(separator: "=", maxSplits: 1)
    guard pieces.count == keyValuePairComponentCount else {
      continue
    }
    components[String(pieces[0])] = String(pieces[1])
  }

  if let identifier = components["id"], !identifier.isEmpty {
    return identifier
  }
  guard let simulatorName = components["name"], !simulatorName.isEmpty else {
    return nil
  }

  let matchingSimulators = try availablePhoneSimulators().filter { simulator in
    simulator.device.name == simulatorName
  }
  guard let simulator = preferredSimulator(from: matchingSimulators) else {
    throw ToolError.failure("no available iPhone simulator named \(simulatorName)")
  }
  return simulator.device.udid
}

func availablePhoneSimulators() throws -> [AvailableSimulator] {
  let result = try capture(
    "xcrun",
    ["simctl", "list", "-j", "devices", "available"],
    echoOutput: false
  )
  guard result.status == 0 else {
    throw ToolError.failure("xcrun simctl list -j devices available failed")
  }

  let deviceList = try JSONDecoder().decode(
    SimulatorDeviceList.self, from: Data(result.output.utf8))
  return deviceList.devices.flatMap { runtimeIdentifier, devices in
    devices.compactMap { device in
      guard device.isAvailable, device.name.hasPrefix("iPhone") else {
        return nil
      }
      return AvailableSimulator(runtimeIdentifier: runtimeIdentifier, device: device)
    }
  }
}

func preferredSimulator(from simulators: [AvailableSimulator]) -> AvailableSimulator? {
  simulators.max { lhs, rhs in
    isPreferredSimulator(lhs: rhs, rhs: lhs)
  }
}

func isPreferredSimulator(lhs: AvailableSimulator, rhs: AvailableSimulator) -> Bool {
  let runtimeComparison = compareVersionComponents(
    lhs: simulatorRuntimeVersion(from: lhs.runtimeIdentifier),
    rhs: simulatorRuntimeVersion(from: rhs.runtimeIdentifier)
  )
  if runtimeComparison != 0 {
    return runtimeComparison > 0
  }

  let lhsBootedAt = lhs.device.lastBootedAt ?? ""
  let rhsBootedAt = rhs.device.lastBootedAt ?? ""
  if lhsBootedAt != rhsBootedAt {
    return lhsBootedAt > rhsBootedAt
  }

  return lhs.device.udid > rhs.device.udid
}

func simulatorRuntimeVersion(from runtimeIdentifier: String) -> [Int] {
  guard let range = runtimeIdentifier.range(of: "iOS-") else {
    return [0]
  }
  return runtimeIdentifier[range.upperBound...]
    .split(separator: "-")
    .compactMap { component in
      Int(component)
    }
}

func createPhoneSimulator() throws -> String {
  let runtime = try preferredSimulatorRuntime()
  let supportedPhoneDeviceTypes = runtime.supportedDeviceTypes.filter { deviceType in
    deviceType.productFamily == "iPhone"
  }
  guard let deviceType = supportedPhoneDeviceTypes.first else {
    throw ToolError.failure(
      "no supported iPhone simulator device type found for \(runtime.name)")
  }

  let simulatorName =
    "\(autoCreatedSimulatorNamePrefix) \(String(UUID().uuidString.prefix(simulatorNameSuffixLength)))"
  let result = try capture(
    "xcrun",
    ["simctl", "create", simulatorName, deviceType.identifier, runtime.identifier],
    echoOutput: false
  )
  guard result.status == 0 else {
    throw ToolError.failure("xcrun simctl create failed")
  }

  let identifier = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !identifier.isEmpty else {
    throw ToolError.failure("created simulator identifier was empty")
  }
  return identifier
}

func preferredSimulatorRuntime() throws -> SimulatorRuntime {
  let result = try capture(
    "xcrun",
    ["simctl", "list", "-j", "runtimes", "available"],
    echoOutput: false
  )
  guard result.status == 0 else {
    throw ToolError.failure("xcrun simctl list -j runtimes available failed")
  }

  let runtimeList = try JSONDecoder().decode(
    SimulatorRuntimeList.self,
    from: Data(result.output.utf8)
  )
  let availableRuntimes = runtimeList.runtimes.filter { runtime in
    runtime.isAvailable && runtime.identifier.contains(".SimRuntime.iOS-")
  }
  guard
    let runtime = availableRuntimes.max(by: { lhs, rhs in
      compareVersionComponents(lhs: lhs.versionComponents, rhs: rhs.versionComponents) < 0
    })
  else {
    throw ToolError.failure("no available iOS simulator runtime found")
  }
  return runtime
}

func bootPhoneSimulator(identifier: String) throws {
  try run("xcrun", ["simctl", "bootstatus", identifier, "-b"])
}

// MARK: - SimulatorRuntime

extension SimulatorRuntime {
  var versionComponents: [Int] {
    version.split(separator: ".").compactMap { component in
      Int(component)
    }
  }
}

func compareVersionComponents(lhs: [Int], rhs: [Int]) -> Int {
  let maxCount = max(lhs.count, rhs.count)
  for index in 0..<maxCount {
    let lhsValue = index < lhs.count ? lhs[index] : 0
    let rhsValue = index < rhs.count ? rhs[index] : 0
    if lhsValue != rhsValue {
      return lhsValue < rhsValue ? -1 : 1
    }
  }
  return 0
}

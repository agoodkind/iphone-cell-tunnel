//
//  GuestSimulator.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let guestSimulatorLogger = CellTunnelLog.logger(category: .build)
private let guestSimulatorNameSuffixLength = 8

// MARK: - GuestSimulator

/// Namesake type so SwiftLint `file_name` matches `GuestSimulator.swift`.
enum GuestSimulator {}

/// Boot a simulator inside the guest, install the transferred iPhone app, and launch
/// it as the relay peer. The simulator hosts the same relay runtime the on-device
/// packet tunnel hosts, so the control link and the forwarder are real.
func launchGuestPhoneApp(shell: GuestShell, layout: GuestInstallLayout) throws -> String {
  let identifier = try guestPhoneSimulatorIdentifier(shell: shell)
  try shell.runRemote(
    "xcrun simctl bootstatus \(identifier) -b",
    describing: "booting the guest simulator \(identifier)"
  )
  try shell.runRemote(
    "xcrun simctl install \(identifier) '\(layout.simulatorAppPath)'",
    describing: "installing the phone app in the guest simulator"
  )
  try shell.runRemote(
    """
    xcrun simctl launch --terminate-running-process \(identifier) \
    \(phoneBundleIdentifier) \(phoneActivationArgument)
    """,
    describing: "launching the phone app in the guest simulator"
  )
  guestSimulatorLogger.notice(
    "guest phone app launched simulator=\(identifier, privacy: .public)")
  printToolOutput("guest: phone app running in simulator \(identifier)")
  return identifier
}

/// The simulator the guest should run the phone app on, creating one when the guest
/// has none.
private func guestPhoneSimulatorIdentifier(shell: GuestShell) throws -> String {
  let simulators = try guestAvailablePhoneSimulators(shell: shell)
  if let simulator = preferredSimulator(from: simulators) {
    return simulator.device.udid
  }
  return try createGuestPhoneSimulator(shell: shell)
}

private func guestAvailablePhoneSimulators(shell: GuestShell) throws -> [AvailableSimulator] {
  let output = try shell.runRemote(
    "xcrun simctl list -j devices available",
    describing: "listing the guest simulators"
  )
  let deviceList = try JSONDecoder().decode(SimulatorDeviceList.self, from: Data(output.utf8))
  return deviceList.devices.flatMap { runtimeIdentifier, devices in
    devices.compactMap { device in
      guard
        device.isAvailable,
        device.name.hasPrefix("iPhone") || device.name.hasPrefix(autoCreatedSimulatorNamePrefix)
      else {
        return nil
      }
      return AvailableSimulator(runtimeIdentifier: runtimeIdentifier, device: device)
    }
  }
}

private func createGuestPhoneSimulator(shell: GuestShell) throws -> String {
  let runtime = try guestPreferredSimulatorRuntime(shell: shell)
  let phoneDeviceTypes = runtime.supportedDeviceTypes.filter { deviceType in
    deviceType.productFamily == "iPhone"
  }
  guard let deviceType = phoneDeviceTypes.first else {
    throw ToolError.failure(
      """
      guest: the \(runtime.name) runtime on the guest supports no iPhone device type, \
      so there is nothing to host the relay peer
      """
    )
  }
  let name =
    "\(autoCreatedSimulatorNamePrefix) "
    + String(UUID().uuidString.prefix(guestSimulatorNameSuffixLength))
  let identifier = try shell.runRemote(
    "xcrun simctl create '\(name)' \(deviceType.identifier) \(runtime.identifier)",
    describing: "creating a phone simulator on the guest"
  )
  guard !identifier.isEmpty else {
    throw ToolError.failure("guest: `simctl create` printed no simulator identifier")
  }
  printToolOutput("guest: created simulator \(name)")
  return identifier
}

private func guestPreferredSimulatorRuntime(shell: GuestShell) throws -> SimulatorRuntime {
  let output = try shell.runRemote(
    "xcrun simctl list -j runtimes available",
    describing: "listing the guest simulator runtimes"
  )
  let runtimeList = try JSONDecoder().decode(SimulatorRuntimeList.self, from: Data(output.utf8))
  let availableRuntimes = runtimeList.runtimes.filter { runtime in
    runtime.isAvailable && runtime.identifier.contains(".SimRuntime.iOS-")
  }
  guard
    let runtime = availableRuntimes.max(by: { lhs, rhs in
      compareVersionComponents(lhs: lhs.versionComponents, rhs: rhs.versionComponents) < 0
    })
  else {
    throw ToolError.failure(
      """
      guest: the guest has no available iOS simulator runtime, so it cannot host the \
      relay peer; install one in the base image
      """
    )
  }
  return runtime
}

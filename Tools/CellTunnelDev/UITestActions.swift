//
//  UITestActions.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import SwiftMkCore

private let uiTestLogger = CellTunnelLog.logger(category: .build)

// MARK: - UITestTarget

enum UITestTarget: String {
  case iphoneSimulator = "iphone-simulator"
  case macCatalyst = "mac-catalyst"
}

// MARK: - UI test command

enum UITestActions {}

func uiTestSimulatorDestination(identifier: String) -> String {
  "platform=iOS Simulator,id=\(identifier)"
}

func uiTestDestination(for target: UITestTarget) throws -> String {
  switch target {
  case .iphoneSimulator:
    let simulatorIdentifier = try selectedPhoneSimulatorIdentifier()
    try bootPhoneSimulator(identifier: simulatorIdentifier)
    return uiTestSimulatorDestination(identifier: simulatorIdentifier)
  case .macCatalyst:
    return "platform=macOS,variant=Mac Catalyst"
  }
}

func runUITests(arguments: [String]) throws {
  let usage = "usage: ui-test <iphone-simulator|mac-catalyst>"
  guard arguments.count == 1, let target = UITestTarget(rawValue: arguments[0]) else {
    throw ToolError.usage(usage)
  }

  try generateProject()
  SigningBuildConfig.applyEnvironmentOverride(localXcconfigPaths: ["Config/local.xcconfig"])
  let destination = try uiTestDestination(for: target)
  uiTestLogger.notice(
    "running UI tests target=\(target.rawValue, privacy: .public) destination=\(destination, privacy: .public)"
  )
  let request = Toolchain.Request(
    generator: .xcodegen,
    scheme: "CellTunnelPhone",
    configuration: "Debug",
    project: "CellTunnel.xcodeproj",
    destination: destination,
    derivedDataPath: derivedDataDirectory.path,
    extraSettings: [
      "SYMROOT": productsDirectory.path,
      "OBJROOT": buildDirectory.appendingPathComponent("Intermediates.noindex").path,
    ],
    extraArguments: ["-only-testing:CellTunnelPhoneUITests"] + xcodeBuildCacheArguments(.enabled)
  )
  guard Toolchain.test(request) == 0 else {
    throw ToolError.failure("toolchain UI test failed for target \(target.rawValue)")
  }
}

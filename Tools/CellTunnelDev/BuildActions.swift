//
//  BuildActions.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import SwiftMkCore

private let logger = CellTunnelLog.logger(category: .build)

func generateProject() throws {
  if try projectGenerationIsCurrent() {
    return
  }
  guard Toolchain.installDependencies(.tuist) == 0 else {
    throw ToolError.failure("toolchain install failed")
  }
  // Under a live gate ancestor keep the make render path unchanged. With no ancestor
  // (a decoupled build) render the generation templates in-process and run the
  // generator directly, so the gated build spawns no swift-mk/make subprocess.
  if GateProof.isCurrentlyGated() {
    try run("make", ["xcconfig-generate-project"])
  } else {
    try renderGeneratedFiles()
    guard Toolchain.generate(.tuist) == 0 else {
      throw ToolError.failure("tuist generate failed")
    }
  }
  try recordProjectGenerationFingerprint()
}

/// Render the project-generation templates in-process from the resolved xcconfig
/// values, the decoupled replacement for `make xcconfig-generate-project`. The render
/// plans mirror the Makefile XCCONFIG_RENDER_PLANS: every `*.template` under each
/// templates directory renders, with its `[[KEY]]` tokens substituted, to the
/// same-named file minus `.template` under the output directory.
private func renderGeneratedFiles() throws {
  let values = XcconfigValues.read(paths: [
    repoRoot.appendingPathComponent("Config/Constants.xcconfig").path,
    repoRoot.appendingPathComponent("Config/local.xcconfig").path,
  ])
  let renderPlans = [
    ("Templates/Swift", "Sources/CellTunnelCore/Generated"),
    ("Templates/Plists", "Derived/Generated/CellTunnelAgent"),
  ]
  var plans: [GeneratedFiles.Plan] = []
  for (templatesDirectory, outputDirectory) in renderPlans {
    let templatesURL = repoRoot.appendingPathComponent(templatesDirectory)
    let entries = try fileManager.contentsOfDirectory(
      at: templatesURL, includingPropertiesForKeys: nil)
    for templateURL in entries where templateURL.pathExtension == "template" {
      let outputName = templateURL.deletingPathExtension().lastPathComponent
      let outputURL =
        repoRoot
        .appendingPathComponent(outputDirectory)
        .appendingPathComponent(outputName)
      plans.append(
        GeneratedFiles.Plan(
          templatePath: templateURL.path,
          outputPath: outputURL.path,
          values: values))
    }
  }
  guard GeneratedFiles.render(plans) else {
    throw ToolError.failure("in-process template render failed")
  }
}

private let projectGenerationSources: [URL] = [
  repoRoot.appendingPathComponent("Project.swift"),
  repoRoot.appendingPathComponent("Tuist.swift"),
  repoRoot.appendingPathComponent("Tuist/Package.swift"),
]

private let projectGenerationFingerprintURL: URL =
  repoRoot
  .appendingPathComponent(".build", isDirectory: true)
  .appendingPathComponent("CellTunnelDev", isDirectory: true)
  .appendingPathComponent("project-fingerprint.txt", isDirectory: false)

private func projectGenerationIsCurrent() throws -> Bool {
  let workspacePath = repoRoot.appendingPathComponent("CellTunnel.xcworkspace").path
  guard fileManager.fileExists(atPath: workspacePath) else {
    return false
  }
  let fingerprint = try projectGenerationSourceFingerprint()
  guard fileManager.fileExists(atPath: projectGenerationFingerprintURL.path) else {
    return false
  }
  let stored = try String(contentsOf: projectGenerationFingerprintURL, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return stored == fingerprint
}

private func recordProjectGenerationFingerprint() throws {
  let fingerprint = try projectGenerationSourceFingerprint()
  let parent = projectGenerationFingerprintURL.deletingLastPathComponent()
  try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
  try fingerprint.write(
    to: projectGenerationFingerprintURL, atomically: true, encoding: .utf8)
}

private func projectGenerationSourceFingerprint() throws -> String {
  var parts: [String] = []
  let team = try developmentTeamFromEnvironment().trimmingCharacters(in: .whitespaces)
  parts.append("team:\(team)")
  for source in projectGenerationSources {
    let attributes = try fileManager.attributesOfItem(atPath: source.path)
    let modificationDate = attributes[.modificationDate] as? Date ?? Date.distantPast
    let size = attributes[.size] as? Int ?? 0
    let fingerprint = "\(modificationDate.timeIntervalSince1970):\(size)"
    parts.append("\(source.lastPathComponent):\(fingerprint)")
  }
  return parts.joined(separator: "|")
}

func buildSwiftProduct(_ productName: String, receipt: GateReceipt? = nil) throws {
  // Route the celltunnelctl compile through the engine SwiftPM chokepoint so it takes
  // the per-worktree build lock and the engine's cache arguments. A receipt authorizes
  // the decoupled path (no make ancestor); without one the make-path GateProof check
  // runs, which refuses a compile outside a live gate.
  let request = SwiftPM.Request(packagePath: repoRoot.path, product: productName)
  let status = receipt.map { SwiftPM.build(request, receipt: $0) } ?? SwiftPM.build(request)
  guard status == 0 else {
    throw ToolError.failure("swift build --product \(productName) failed (status \(status))")
  }
}

func installSwiftExecutable(productName: String, outputName: String) throws {
  // Resolve the package's built-products directory through the engine. `binPath` is a
  // no-artifact query, so it needs no gate, but it still takes the build lock.
  guard let binPath = SwiftPM.binPath(SwiftPM.Request(packagePath: repoRoot.path)) else {
    throw ToolError.failure("swift build --show-bin-path failed")
  }
  let source = URL(fileURLWithPath: binPath).appendingPathComponent(productName)
  let destination = productsDirectory.appendingPathComponent(outputName)
  guard fileManager.fileExists(atPath: source.path) else {
    throw ToolError.failure("built Swift executable not found: \(source.path)")
  }

  try copyReplacingItem(at: source, to: destination)
  try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
}

func buildScheme(
  scheme: String,
  configuration: String,
  destination: String,
  platformName: String,
  action: String = "build",
  xcodebuildOptions: [String] = [],
  buildSettings: [String: String] = [:],
  receipt: GateReceipt? = nil
) throws {
  // swift-mk owns build-time signing. This dev tool builds through Toolchain
  // without the make prelude, so apply the same XCODE_XCCONFIG_FILE override here.
  // It is a no-op when the prelude already exported it, reads team/identity/style
  // from the environment then Config/local.xcconfig, and sets no signing per target.
  // Toolchain.build/analyze then sees the override already set and inherits it.
  SigningBuildConfig.applyEnvironmentOverride(localXcconfigPaths: ["Config/local.xcconfig"])
  logger.notice(
    """
    toolchain scheme=\(scheme, privacy: .public) action=\(action, privacy: .public) \
    configuration=\(configuration, privacy: .public) platform=\(platformName, privacy: .public)
    """
  )
  let configurationBuildDirectory = xcodeConfigurationBuildDirectory(
    configuration: configuration,
    platformName: platformName
  )
  try fileManager.createDirectory(
    at: configurationBuildDirectory, withIntermediateDirectories: true)
  var settings = [
    "SYMROOT": productsDirectory.path,
    "OBJROOT": buildDirectory.appendingPathComponent("Intermediates.noindex").path,
  ]
  for (key, value) in buildSettings {
    settings[key] = value
  }
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: scheme,
    configuration: configuration,
    workspace: "CellTunnel.xcworkspace",
    destination: destination,
    derivedDataPath: derivedDataDirectory.path,
    extraSettings: settings,
    extraArguments: xcodebuildOptions + xcodeBuildCacheArguments(.enabled)
  )
  // A receipt routes the product compile through the capability path, which a
  // decoupled build with no make ancestor uses: GatedBuild.run mints the receipt
  // only after the hard gate passes, so Toolchain.build(_:receipt:) skips the
  // GateProof ancestry check the make path keeps. Without a receipt the compile
  // takes the GateProof make path, refused unless a live gate ancestor exists.
  let status: Int32
  if action == "analyze" {
    status = Toolchain.analyze(request)
  } else if let receipt {
    status = Toolchain.build(request, receipt: receipt)
  } else {
    status = Toolchain.build(request)
  }
  guard status == 0 else {
    throw ToolError.failure("toolchain \(action) failed for scheme \(scheme)")
  }
}

func buildPhoneDevice(configuration: String) throws {
  try buildPhoneDevice(
    configuration: configuration,
    shouldGenerateProject: true,
    receipt: nil
  )
}

// Signing follow-ups not implemented this pass, recorded so the next pass has the
// recipe.
// macOS Developer ID notarization: package CellTunnelAgent.app with ditto, run
// xcrun notarytool submit --wait using the APPLE_NOTARY_* key, verify Accepted,
// then xcrun stapler staple.
// CI release: add .github/workflows/release.yml that builds with the App Store
// Connect key, notarizes, and publishes, mirroring macos-fan-curve and reusing the
// same secret names.
func buildPhoneDevice(
  configuration: String,
  shouldGenerateProject: Bool,
  receipt: GateReceipt? = nil
) throws {
  logger.notice(
    "building phone device configuration=\(configuration, privacy: .public)")
  if shouldGenerateProject {
    try generateProject()
  }
  try buildScheme(
    scheme: "CellTunnelPhone",
    configuration: configuration,
    destination: ProcessInfo.processInfo.environment["IOS_DEVICE_DESTINATION"]
      ?? "generic/platform=iOS",
    platformName: iOSDevicePlatformName,
    xcodebuildOptions: try ["-allowProvisioningUpdates"] + appStoreConnectAuthArguments(),
    receipt: receipt
  )
}

func installPhoneDevice(configuration: String) throws {
  try buildPhoneDevice(configuration: configuration)
  try installBuiltPhoneDevice(configuration: configuration)
}

func installBuiltPhoneDevice(configuration: String) throws {
  let deviceIdentifier = try selectedPhoneDeviceIdentifier()
  let appPath = phoneDeviceAppPath(configuration: configuration)
  guard fileManager.fileExists(atPath: appPath.path) else {
    throw ToolError.failure("built phone app not found: \(appPath.path)")
  }
  try run(
    "xcrun",
    [
      "devicectl",
      "device",
      "install",
      "app",
      "--device",
      deviceIdentifier,
      appPath.path,
    ]
  )
}

func launchPhoneDevice() throws {
  try launchInstalledPhoneDevice()
}

// MARK: - WireGuard Go bridge

/// The wireguard-apple Go bridge sources, vendored through Tuist.
private let wireGuardGoBridgeSourcePath: URL =
  repoRoot
  .appendingPathComponent("Tuist", isDirectory: true)
  .appendingPathComponent(".build", isDirectory: true)
  .appendingPathComponent("checkouts", isDirectory: true)
  .appendingPathComponent("wireguard-apple", isDirectory: true)
  .appendingPathComponent("Sources", isDirectory: true)
  .appendingPathComponent("WireGuardKitGo", isDirectory: true)

/// Where `libwg-go.a` lands so WireGuardKit's `LIBRARY_SEARCH_PATHS` finds it.
private let wireGuardGoBridgeLibraryDirectory: URL =
  repoRoot
  .appendingPathComponent(".build", isDirectory: true)
  .appendingPathComponent("vendor", isDirectory: true)

/// Scratch directory for the bridge build.
private let wireGuardGoBridgeTempDirectory: URL =
  repoRoot
  .appendingPathComponent(".build", isDirectory: true)
  .appendingPathComponent("vendor-temp", isDirectory: true)

/// Builds the WireGuard Go bridge static library before xcodebuild runs. The
/// library is consumed by WireGuardKit's `WireGuardKitGo` target, an external
/// Tuist-generated target with no dependencies that links `-lwg-go` and so
/// builds first in the graph. No xcodebuild build phase can produce the library
/// in time, so it is built here, at the start of every build, before the
/// xcodebuild graph starts.
func buildWireGuardGoBridge() throws {
  guard fileManager.fileExists(atPath: wireGuardGoBridgeSourcePath.path) else {
    throw ToolError.failure(
      """
      wireguard-apple WireGuardKitGo source not found at \
      \(wireGuardGoBridgeSourcePath.path); run tuist install first
      """
    )
  }
  try fileManager.createDirectory(
    at: wireGuardGoBridgeLibraryDirectory, withIntermediateDirectories: true)
  try fileManager.createDirectory(
    at: wireGuardGoBridgeTempDirectory, withIntermediateDirectories: true)
  try run(
    "make",
    [
      "-C", wireGuardGoBridgeSourcePath.path,
      "build",
    ],
    environment: [
      "CONFIGURATION_BUILD_DIR": wireGuardGoBridgeLibraryDirectory.path,
      "CONFIGURATION_TEMP_DIR": wireGuardGoBridgeTempDirectory.path,
      "ARCHS": "arm64",
      "PLATFORM_NAME": "macosx",
    ]
  )
}

func selectedPhoneDeviceIdentifier() throws -> String {
  let environment = ProcessInfo.processInfo.environment
  for key in ["CELL_TUNNEL_IOS_DEVICE_ID", "IOS_DEVICE_ID", "IOS_DEVICE_UDID"] {
    if let value = environment[key], !value.isEmpty {
      return value
    }
  }

  let result = try capture("xcrun", ["xcdevice", "list"], echoOutput: false)
  guard result.status == 0 else {
    throw ToolError.failure("xcrun xcdevice list failed")
  }
  let devices = try JSONDecoder().decode([XcodeDevice].self, from: Data(result.output.utf8))
  let availablePhones = devices.filter { device in
    !device.simulator && device.available && device.platform == "com.apple.platform.iphoneos"
  }
  guard availablePhones.count == 1, let phone = availablePhones.first else {
    let names = availablePhones.map { "\($0.name) (\($0.identifier))" }.joined(separator: ", ")
    throw ToolError.failure(
      "expected one available iPhone device, found \(availablePhones.count): \(names)")
  }
  return phone.identifier
}
func testProject() throws {
  // The engine make-path SwiftPM.test runs the GateProof check itself, so this routes
  // the test run through the chokepoint (lock, cache, gate) instead of spawning `swift`.
  let status = SwiftPM.test(
    SwiftPM.TestRequest(package: SwiftPM.Request(packagePath: repoRoot.path)))
  guard status == 0 else {
    throw ToolError.failure("swift test failed (status \(status))")
  }
}

// Lint and format are delegated to SwiftMkCore, which is the library that
// backs the `swift-mk lint` and `swift-mk fmt` CLI subcommands. SwiftMkCore
// owns the tool-resolution, config-resolution, file-list, and exclude-path
// policy. The PathContext is read from the current working directory.

func lintProject() throws {
  if !Lint.runLint(context: PathContext.current()) {
    throw ToolError.failure("lint failed")
  }
}

func formatProject() throws {
  if !Lint.runFmt(context: PathContext.current()) {
    throw ToolError.failure("fmt failed")
  }
}

func analyzeProject() throws {
  try requireTool("swiftlint")
  try requireTool("periphery")
  try generateProject()
  try xcodeAnalyze()
  try swiftLintAnalyze()
  try run("periphery", ["scan", "--config", ".periphery.yml"])
}

func xcodeAnalyze() throws {
  try buildScheme(
    scheme: "CellTunnelAgent",
    configuration: "Debug",
    destination: "platform=macOS",
    platformName: macOSPlatformName,
    action: "analyze"
  )
  try buildScheme(
    scheme: "CellTunnelTunnelProvider",
    configuration: "Debug",
    destination: "platform=macOS",
    platformName: macOSPlatformName,
    action: "analyze"
  )
  try buildScheme(
    scheme: "CellTunnelPhone",
    configuration: "Debug",
    destination: ProcessInfo.processInfo.environment["IOS_SIMULATOR_DESTINATION"]
      ?? "generic/platform=iOS Simulator",
    platformName: iOSSimulatorPlatformName,
    action: "analyze"
  )
}

func swiftLintAnalyze() throws {
  logger.notice("swiftlint analyze compiler-log build starting")
  let analyzeDirectory = buildDirectory.appendingPathComponent("Analyze")
  try fileManager.createDirectory(at: analyzeDirectory, withIntermediateDirectories: true)
  let compilerLog = analyzeDirectory.appendingPathComponent("swiftlint-xcodebuild.log")
  // Sign this compiler-log build the same way every other build path does, so the
  // analyze build never silently falls back to ad-hoc.
  SigningBuildConfig.applyEnvironmentOverride(localXcconfigPaths: ["Config/local.xcconfig"])
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "CellTunnelAgent",
    configuration: "Debug",
    workspace: "CellTunnel.xcworkspace",
    destination: "platform=macOS",
    derivedDataPath: analyzeDirectory.appendingPathComponent("SwiftLintDerivedData").path,
    extraArguments: xcodeBuildCacheArguments(.disabled)
  )
  let status = Toolchain.buildWritingLog(request, logPath: compilerLog.path, clean: true)
  guard status == 0 else {
    throw ToolError.failure("toolchain compiler-log build failed with status \(status)")
  }
  try run(
    "swiftlint",
    [
      "analyze",
      "--strict",
      "--config",
      ".swiftlint.yml",
      "--compiler-log-path",
      compilerLog.path,
    ]
  )
}

func cleanProject() throws {
  logger.notice("cleaning build and product outputs")
  let paths = [
    buildDirectory,
    productsDirectory,
    repoRoot.appendingPathComponent(".build"),
    repoRoot.appendingPathComponent("Tools/.build"),
    repoRoot.appendingPathComponent("CellTunnel.xcodeproj"),
    repoRoot.appendingPathComponent("CellTunnel.xcworkspace"),
  ]

  for path in paths where fileManager.fileExists(atPath: path.path) {
    try fileManager.removeItem(at: path)
  }
}

// Signature verification is owned by swift-mk: the `build` make target runs
// `verify-signing settings` before the build and `verify-signing artifacts` after,
// declared by the SWIFT_MK_VERIFY_* variables in the Makefile. Keeping it out of the
// dev tool means the dead-code coverage build (which runs the dev tool with signing
// disabled, outside the `build` target) is never signature-verified, so it no longer
// aborts the gate.

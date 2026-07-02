//
//  BuildDispatch.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import SwiftMkCore

enum BuildDispatch {}

private let buildDispatchLogger = CellTunnelLog.logger(category: .build)

// MARK: - BuildTarget

enum BuildTarget: String, CaseIterable {
  case all
  case daemon
  case iphoneDevice = "iphone-device"
  case iphoneSimulator = "iphone-simulator"
  case mac
  case macCatalyst = "mac-catalyst"
}

let buildTargetUsage = BuildTarget.allCases.map(\.rawValue).joined(separator: "|")

func buildProject(target: BuildTarget, configuration: String) throws {
  try buildProjects(targets: [target], configuration: configuration)
}

/// Build one or more targets. A decoupled multi-target build, the way
/// `clean-reinstall` builds the Mac agent and the iPhone app, runs every target's
/// compile under a single `GatedBuild.run` so one hard gate authorizes them all.
///
/// Two authorized paths to the same compile. Under `make` (or the deadcode coverage
/// sub-build that `make check` shells), a live swift-mk gate ancestor authorizes
/// Toolchain.build through GateProof, so run the existing prologue-then-compile flow
/// unchanged. With no such ancestor (a direct `cell-tunnel-dev build`), run swift-mk's
/// hard lint gate in-process through GatedBuild.run and compile with the minted
/// receipt. Routing on the gate probe keeps the make path byte-identical and stops
/// the in-make coverage sub-build from re-entering the gate.
func buildProjects(targets: [BuildTarget], configuration: String) throws {
  if GateProof.isCurrentlyGated() {
    try runBuildPrologue()
    try buildCLI()
    for target in targets {
      try buildTargets(target: target, configuration: configuration, receipt: nil)
    }
  } else {
    try buildDecoupled(targets: targets, configuration: configuration)
  }

  for target in targets {
    try printBuildArtifactFingerprints(target: target, configuration: configuration)
  }
}

// MARK: - Decoupled gated build

/// Build with no `make`/`swift-mk` ancestor by running swift-mk's hard lint gate
/// in-process, then compiling under the receipt the gate mints. The generation and
/// log-audit steps the make prologue runs become gate hooks so they run inside the
/// gate, and the WireGuard Go bridge builds inside the compile closure, after the
/// gate passes and before the xcodebuild graph that links it.
private func buildDecoupled(targets: [BuildTarget], configuration: String) throws {
  let names = targets.map(\.rawValue).joined(separator: ",")
  buildDispatchLogger.notice(
    """
    decoupled gated build targets=\(names, privacy: .public) \
    configuration=\(configuration, privacy: .public)
    """
  )
  try buildCLI()
  // The dead-code gate reads the index store from SWIFT_MK_DERIVED_DATA; the make
  // layer exports it, so the decoupled path sets the same path the build writes to.
  setenv("SWIFT_MK_DERIVED_DATA", derivedDataDirectory.path, 1)
  // The decoupled gate runs swift-mk's dead-code coverage-completeness check, which
  // needs the engine's Xcode coverage build to index the app sources (Apps/ targets are
  // not SwiftPM targets). The make path gets these from swift.mk's exports; with no make
  // ancestor, set them here, mirroring the Makefile's SWIFT_XCODE_* declarations.
  setenv("SWIFT_MK_XCODE_BUILD", "1", 1)
  setenv("SWIFT_XCODE_WORKSPACE", "CellTunnel.xcworkspace", 1)
  setenv("SWIFT_XCODE_GENERATOR", Toolchain.Generator.tuist.rawValue, 1)
  setenv("SWIFT_XCODE_COVERAGE_CONFIGURATION", configuration, 1)
  setenv("SWIFT_XCODE_PREBUILD_CMD", "swift Tools/cell-tunnel-dev.swift prebuild", 1)
  let request = GatedBuild.Request(
    entry: "cell-tunnel-dev build \(names)",
    signing: GatedBuild.SigningOptions(localXcconfigPaths: ["Config/local.xcconfig"]),
    hooks: GatedBuild.Hooks(
      generate: decoupledGenerateHook,
      logAudit: decoupledLogAuditHook
    )
  ) { receipt in
    decoupledCompile(targets: targets, configuration: configuration, receipt: receipt)
  }
  let status = GatedBuild.run(request)
  guard status == 0 else {
    throw ToolError.failure(
      "gated build failed for targets \(names) status \(status)")
  }
}

/// Generate the Xcode project as the gate's generation hook, returning success so the
/// gate can stop before discovery when generation fails. The WireGuard Go bridge is
/// built per build phase (coverage matrix, receipt compile) rather than here, because
/// `.build/vendor` does not survive from this hook to those phases.
private func decoupledGenerateHook() -> Bool {
  do {
    try generateProject()
    return true
  } catch {
    buildDispatchLogger.error(
      "decoupled generate failed details=\(error.localizedDescription, privacy: .public)")
    return false
  }
}

/// Run the logging audit as the gate's log-audit hook.
private func decoupledLogAuditHook() -> Bool {
  do {
    try auditLogging()
    return true
  } catch {
    buildDispatchLogger.error(
      "decoupled log-audit failed details=\(error.localizedDescription, privacy: .public)")
    return false
  }
}

/// The gate-authorized compile: build the WireGuard Go bridge, then compile every
/// scheme for every target with the minted receipt. The bridge is rebuilt here because
/// `.build/vendor` does not survive from the gate's coverage phase, and WireGuardKitGo
/// links `libwg-go.a` from it. Returns the first nonzero status.
private func decoupledCompile(
  targets: [BuildTarget], configuration: String, receipt: GateReceipt
) -> Int32 {
  do {
    try buildWireGuardGoBridge()
    for target in targets {
      try buildTargets(target: target, configuration: configuration, receipt: receipt)
    }
    return 0
  } catch {
    buildDispatchLogger.error(
      "decoupled compile failed details=\(error.localizedDescription, privacy: .public)")
    return 1
  }
}

/// Compile every scheme for a build target. A non-nil receipt routes each scheme
/// through the in-process capability path; nil keeps the GateProof make path.
func buildTargets(target: BuildTarget, configuration: String, receipt: GateReceipt?) throws {
  // Code-signing identity, team, and style come from swift-mk, which exports an
  // XCODE_XCCONFIG_FILE override that wins over Tuist's per-target
  // CODE_SIGN_IDENTITY = - default, so no build here sets signing per scheme.
  switch target {
  case .daemon:
    try buildMacAgent(configuration: configuration, receipt: receipt)
  case .mac:
    try buildMacAgent(configuration: configuration, receipt: receipt)
    try buildMacTunnelProvider(configuration: configuration, receipt: receipt)
  case .macCatalyst:
    try buildMacCatalyst(configuration: configuration, receipt: receipt)
  case .iphoneSimulator:
    try buildIPhoneSimulator(configuration: configuration, receipt: receipt)
  case .iphoneDevice:
    try buildPhoneDevice(
      configuration: configuration,
      shouldGenerateProject: false,
      receipt: receipt
    )
  case .all:
    try buildMacAgent(configuration: configuration, receipt: receipt)
    try buildMacTunnelProvider(configuration: configuration, receipt: receipt)
    try buildIPhoneSimulator(configuration: configuration, receipt: receipt)
    try buildPhoneDevice(
      configuration: configuration,
      shouldGenerateProject: false,
      receipt: receipt
    )
  }
}

private func runBuildPrologue() throws {
  buildDispatchLogger.notice("build prologue starting generate, audit, wireguard go bridge")
  try generateProject()
  try auditLogging()
  // Build the WireGuard Go bridge before any xcodebuild target. Every build
  // target routes through this prologue, so no target path can skip it, and the
  // library exists before WireGuardKit's WireGuardKitGo target links it.
  try buildWireGuardGoBridge()
}

private func buildCLI() throws {
  try buildSwiftProduct("celltunnelctl")
  try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
  try installSwiftExecutable(productName: "celltunnelctl", outputName: "celltunnelctl")
}

private func buildMacAgent(configuration: String, receipt: GateReceipt? = nil) throws {
  buildDispatchLogger.notice(
    "building CellTunnelAgent scheme configuration=\(configuration, privacy: .public)"
  )
  try buildScheme(
    scheme: "CellTunnelAgent",
    configuration: configuration,
    destination: "platform=macOS",
    platformName: macOSPlatformName,
    xcodebuildOptions: try ["-allowProvisioningUpdates"] + appStoreConnectAuthArguments(),
    receipt: receipt
  )
}

private func buildMacTunnelProvider(configuration: String, receipt: GateReceipt? = nil) throws {
  buildDispatchLogger.notice(
    "building CellTunnelTunnelProvider scheme configuration=\(configuration, privacy: .public)"
  )
  try buildScheme(
    scheme: "CellTunnelTunnelProvider",
    configuration: configuration,
    destination: "platform=macOS",
    platformName: macOSPlatformName,
    xcodebuildOptions: try ["-allowProvisioningUpdates"] + appStoreConnectAuthArguments(),
    receipt: receipt
  )
}

private func buildIPhoneSimulator(configuration: String, receipt: GateReceipt? = nil) throws {
  try buildScheme(
    scheme: "CellTunnelPhone",
    configuration: configuration,
    destination: ProcessInfo.processInfo.environment["IOS_SIMULATOR_DESTINATION"]
      ?? "generic/platform=iOS Simulator",
    platformName: iOSSimulatorPlatformName,
    receipt: receipt
  )
}

// Builds the iPhone app target as a Mac Catalyst product. The same
// CellTunnelPhone scheme yields the iPhone app and the Mac app; the destination
// variant selects the Mac Catalyst slice, and the Mac build reads the agent over
// XPC rather than hosting a tunnel. The Catalyst entitlements require a
// development certificate, so signing is supplied the way the iPhone device build
// supplies it.
private func buildMacCatalyst(configuration: String, receipt: GateReceipt? = nil) throws {
  buildDispatchLogger.notice(
    "building CellTunnelPhone Mac Catalyst configuration=\(configuration, privacy: .public)"
  )
  try buildScheme(
    scheme: "CellTunnelPhone",
    configuration: configuration,
    destination: "generic/platform=macOS,variant=Mac Catalyst",
    platformName: macCatalystPlatformName,
    xcodebuildOptions: try ["-allowProvisioningUpdates"] + appStoreConnectAuthArguments(),
    receipt: receipt
  )
}

private func printBuildArtifactFingerprints(target: BuildTarget, configuration: String) throws {
  let ctlPath = productsDirectory.appendingPathComponent("celltunnelctl").path
  let macBuildDir = xcodeConfigurationBuildDirectory(
    configuration: configuration,
    platformName: macOSPlatformName
  )
  let agentPath = macBuildDir.appendingPathComponent("CellTunnelAgent").path
  let extensionPath = macBuildDir.appendingPathComponent("CellTunnelTunnelProvider.appex").path
  buildDispatchLogger.notice(
    """
    build artifacts target=\(target.rawValue, privacy: .public) \
    configuration=\(configuration, privacy: .public)
    """
  )
  try printArtifactFingerprint(label: "celltunnelctl", path: ctlPath)
  if target == .daemon || target == .mac || target == .all {
    try printArtifactFingerprint(label: "CellTunnelAgent", path: agentPath)
  }
  if target == .mac || target == .all {
    if fileManager.fileExists(atPath: extensionPath) {
      buildDispatchLogger.notice(
        "build artifact present label=CellTunnelTunnelProvider path=\(extensionPath, privacy: .public)"
      )
    } else {
      buildDispatchLogger.notice(
        "build artifact missing label=CellTunnelTunnelProvider path=\(extensionPath, privacy: .public)"
      )
    }
  }
}

private func printArtifactFingerprint(label: String, path: String) throws {
  if !fileManager.fileExists(atPath: path) {
    buildDispatchLogger.notice(
      "build artifact missing label=\(label, privacy: .public) path=\(path, privacy: .public)"
    )
    return
  }
  let result = try capture("shasum", ["-a", "256", path], echoOutput: false)
  if result.status == 0 {
    let line = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    buildDispatchLogger.notice(
      "build artifact fingerprint label=\(label, privacy: .public) line=\(line, privacy: .public)"
    )
  } else {
    buildDispatchLogger.error(
      """
      build artifact shasum failed label=\(label, privacy: .public) \
      status=\(result.status, privacy: .public)
      """
    )
  }
}

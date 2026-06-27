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
  // Two authorized paths to the same compile. Under `make` (or the deadcode coverage
  // sub-build that `make check` shells), a live swift-mk gate ancestor authorizes
  // Toolchain.build through GateProof, so run the existing prologue-then-compile flow
  // unchanged. With no such ancestor (a direct `cell-tunnel-dev build`), run swift-mk's
  // hard lint gate in-process through GatedBuild.run and compile with the minted
  // receipt. Routing on the gate probe keeps the make path byte-identical and stops
  // the in-make coverage sub-build from re-entering the gate.
  if GateProof.isCurrentlyGated() {
    try runBuildPrologue()
    try buildCLI()
    try buildTargets(target: target, configuration: configuration, receipt: nil)
  } else {
    try buildDecoupled(target: target, configuration: configuration)
  }

  try printBuildArtifactFingerprints(target: target, configuration: configuration)
}

// MARK: - Decoupled gated build

/// Build with no `make`/`swift-mk` ancestor by running swift-mk's hard lint gate
/// in-process, then compiling under the receipt the gate mints. The generation and
/// log-audit steps the make prologue runs become gate hooks so they run inside the
/// gate, and the WireGuard Go bridge builds inside the compile closure, after the
/// gate passes and before the xcodebuild graph that links it.
private func buildDecoupled(target: BuildTarget, configuration: String) throws {
  buildDispatchLogger.notice(
    """
    decoupled gated build target=\(target.rawValue, privacy: .public) \
    configuration=\(configuration, privacy: .public)
    """
  )
  try buildCLI()
  // The dead-code gate reads the index store from SWIFT_MK_DERIVED_DATA; the make
  // layer exports it, so the decoupled path sets the same path the build writes to.
  setenv("SWIFT_MK_DERIVED_DATA", derivedDataDirectory.path, 1)
  let request = GatedBuild.Request(
    entry: "cell-tunnel-dev build \(target.rawValue)",
    signing: GatedBuild.SigningOptions(localXcconfigPaths: ["Config/local.xcconfig"]),
    hooks: GatedBuild.Hooks(
      generate: decoupledGenerateHook,
      deadcodeCoverage: { authorization, environment in
        decoupledDeadcodeCoverage(authorization, environment, configuration: configuration)
      },
      logAudit: decoupledLogAuditHook
    )
  ) { receipt in
    decoupledCompile(target: target, configuration: configuration, receipt: receipt)
  }
  let status = GatedBuild.run(request)
  guard status == 0 else {
    throw ToolError.failure(
      "gated build failed for target \(target.rawValue) status \(status)")
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

/// The in-process dead-code coverage build for the decoupled gate. Mirrors the make
/// `SWIFT_DEADCODE_BUILD_CMD` four-target matrix (CellTunnelAgent macOS,
/// CellTunnelTunnelProvider macOS, CellTunnelPhone Mac Catalyst, CellTunnelPhone iOS
/// Simulator, no device slice) so both targetEnvironment(macCatalyst) branches are
/// indexed. Each target builds for testing under the gate's coverage capability and
/// the signing-disabled `environment`, writing the index into the build's derived
/// data; no SYMROOT or OBJROOT is set here so swift-mk's `DeadcodeBuildConfig` owns
/// them. Returns the combined status and captured output for the gate's fail-hard
/// diagnosis.
private func decoupledDeadcodeCoverage(
  _ authorization: DeadcodeCoverageAuthorization,
  _ environment: [String: String],
  configuration: String
) -> DeadcodeCoverageResult {
  buildDispatchLogger.notice(
    "decoupled deadcode coverage matrix configuration=\(configuration, privacy: .public)")
  // Rebuild from a clean derived-data directory so the index reflects the current
  // sources, matching the make path's `rm -rf $(SWIFT_MK_DERIVED_DATA)`. A missing
  // directory is the expected first-run case; any other removal error is logged
  // rather than discarded, since a stale directory left behind risks a partial index.
  do {
    try fileManager.removeItem(at: derivedDataDirectory)
  } catch {
    // The first coverage build has nothing to remove; any other error is logged
    // rather than discarded, since a stale directory risks a partial index.
    buildDispatchLogger.notice(
      """
      deadcode coverage derived-data not removed \
      details=\(error.localizedDescription, privacy: .public)
      """
    )
  }
  // Build the WireGuard Go bridge immediately before the matrix so `.build/vendor`
  // holds `libwg-go.a` when WireGuardKitGo links; an earlier build of it does not
  // survive to here, and a missing search path fails the coverage build.
  do {
    try buildWireGuardGoBridge()
  } catch {
    buildDispatchLogger.error(
      """
      deadcode coverage bridge build failed \
      details=\(error.localizedDescription, privacy: .public)
      """
    )
    return DeadcodeCoverageResult(status: 1, output: "WireGuard Go bridge build failed")
  }
  let matrix: [(scheme: String, destination: String)] = [
    ("CellTunnelAgent", "platform=macOS"),
    ("CellTunnelTunnelProvider", "platform=macOS"),
    ("CellTunnelPhone", "generic/platform=macOS,variant=Mac Catalyst"),
    (
      "CellTunnelPhone",
      ProcessInfo.processInfo.environment["IOS_SIMULATOR_DESTINATION"]
        ?? "generic/platform=iOS Simulator"
    ),
  ]
  var combinedOutput = ""
  for entry in matrix {
    let request = Toolchain.Request(
      generator: .tuist,
      scheme: entry.scheme,
      configuration: configuration,
      workspace: "CellTunnel.xcworkspace",
      destination: entry.destination,
      derivedDataPath: derivedDataDirectory.path,
      extraArguments: xcodeBuildCacheArguments(.enabled)
    )
    let result = Toolchain.buildForTestingCapturingOutput(
      request, authorization: authorization, environment: environment)
    combinedOutput += result.stdout
    if result.status != 0 {
      return DeadcodeCoverageResult(status: result.status, output: combinedOutput)
    }
  }
  return DeadcodeCoverageResult(status: 0, output: combinedOutput)
}

/// The gate-authorized compile: build the WireGuard Go bridge, then compile every
/// scheme for the target with the minted receipt. The bridge is rebuilt here because
/// `.build/vendor` does not survive from the gate's coverage phase, and WireGuardKitGo
/// links `libwg-go.a` from it. Returns the first nonzero status.
private func decoupledCompile(
  target: BuildTarget, configuration: String, receipt: GateReceipt
) -> Int32 {
  do {
    try buildWireGuardGoBridge()
    try buildTargets(target: target, configuration: configuration, receipt: receipt)
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

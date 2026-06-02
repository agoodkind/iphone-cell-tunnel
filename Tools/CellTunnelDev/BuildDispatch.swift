//
//  BuildDispatch.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

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
    try runBuildPrologue()
    try buildCLI()

    switch target {
    case .daemon:
        try buildMacAgent(configuration: configuration)
    case .mac:
        try buildMacAgent(configuration: configuration)
        try buildMacTunnelProvider(configuration: configuration)
    case .macCatalyst:
        let team = try developmentTeamFromEnvironment()
        try buildMacCatalyst(configuration: configuration, developmentTeam: team)
    case .iphoneSimulator:
        try buildIPhoneSimulator(configuration: configuration)
    case .iphoneDevice:
        let team = try developmentTeamFromEnvironment()
        try buildPhoneDevice(
            configuration: configuration,
            developmentTeam: team,
            shouldGenerateProject: false
        )
    case .all:
        let team = try developmentTeamFromEnvironment()
        try buildMacAgent(configuration: configuration)
        try buildMacTunnelProvider(configuration: configuration)
        try buildIPhoneSimulator(configuration: configuration)
        try buildPhoneDevice(
            configuration: configuration,
            developmentTeam: team,
            shouldGenerateProject: false
        )
    }

    try printBuildArtifactFingerprints(target: target, configuration: configuration)
}

private func runBuildPrologue() throws {
    try generateProject()
    try auditLogging()
}

private func buildCLI() throws {
    try buildSwiftProduct("celltunnelctl")
    try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
    try installSwiftExecutable(productName: "celltunnelctl", outputName: "celltunnelctl")
}

private func buildMacAgent(configuration: String) throws {
    buildDispatchLogger.notice(
        "building CellTunnelAgent scheme configuration=\(configuration, privacy: .public)"
    )
    try buildWireGuardGoBridge()
    try buildScheme(
        scheme: "CellTunnelAgent",
        configuration: configuration,
        destination: "platform=macOS",
        platformName: macOSPlatformName,
        xcodebuildOptions: ["-allowProvisioningUpdates"]
    )
}

private func buildMacTunnelProvider(configuration: String) throws {
    buildDispatchLogger.notice(
        "building CellTunnelTunnelProvider scheme configuration=\(configuration, privacy: .public)"
    )
    try buildWireGuardGoBridge()
    try buildScheme(
        scheme: "CellTunnelTunnelProvider",
        configuration: configuration,
        destination: "platform=macOS",
        platformName: macOSPlatformName,
        xcodebuildOptions: ["-allowProvisioningUpdates"]
    )
}

private func buildIPhoneSimulator(configuration: String) throws {
    try buildScheme(
        scheme: "CellTunnelPhone",
        configuration: configuration,
        destination: ProcessInfo.processInfo.environment["IOS_SIMULATOR_DESTINATION"]
            ?? "generic/platform=iOS Simulator",
        platformName: iOSSimulatorPlatformName
    )
}

// Builds the iPhone app target as a Mac Catalyst product. The same
// CellTunnelPhone scheme yields the iPhone app and the Mac app; the destination
// variant selects the Mac Catalyst slice, and the Mac build reads the agent over
// XPC rather than hosting a tunnel. The Catalyst entitlements require a
// development certificate, so signing is supplied the way the iPhone device build
// supplies it.
private func buildMacCatalyst(configuration: String, developmentTeam: String) throws {
    buildDispatchLogger.notice(
        "building CellTunnelPhone Mac Catalyst configuration=\(configuration, privacy: .public)"
    )
    try buildScheme(
        scheme: "CellTunnelPhone",
        configuration: configuration,
        destination: "generic/platform=macOS,variant=Mac Catalyst",
        platformName: macCatalystPlatformName,
        xcodebuildOptions: try ["-allowProvisioningUpdates"] + appStoreConnectAuthArguments(),
        buildSettings: [
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": developmentTeam,
        ]
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

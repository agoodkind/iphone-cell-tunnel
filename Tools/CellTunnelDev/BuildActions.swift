import Foundation
import SwiftMkCore

func generateProject() throws {
    try requireTool("tuist")
    if try projectGenerationIsCurrent() {
        return
    }
    try run("tuist", ["install"])
    try run("make", ["xcconfig-generate-project"])
    try recordProjectGenerationFingerprint()
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

func buildSwiftProduct(_ productName: String) throws {
    try run("swift", swiftBuildArguments(["--product", productName]))
}

func installSwiftExecutable(productName: String, outputName: String) throws {
    let binPathResult = try capture(
        "swift",
        swiftBuildArguments(["--show-bin-path"]),
        echoOutput: false
    )
    guard binPathResult.status == 0 else {
        throw ToolError.failure("swift build --show-bin-path failed")
    }

    let binPath = binPathResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
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
    buildSettings: [String: String] = [:]
) throws {
    let configurationBuildDirectory = xcodeConfigurationBuildDirectory(
        configuration: configuration,
        platformName: platformName
    )
    try fileManager.createDirectory(
        at: configurationBuildDirectory, withIntermediateDirectories: true)
    var arguments = [
        "-workspace",
        "CellTunnel.xcworkspace",
        "-scheme",
        scheme,
        "-configuration",
        configuration,
        "-destination",
        destination,
        "-derivedDataPath",
        derivedDataDirectory.path,
    ]
    arguments.append(contentsOf: xcodebuildOptions)
    arguments.append(contentsOf: xcodeBuildCacheArguments(.enabled))
    arguments.append(contentsOf: [
        "SYMROOT=\(buildDirectory.path)",
        "OBJROOT=\(buildDirectory.appendingPathComponent("Intermediates.noindex").path)",
        "CONFIGURATION_BUILD_DIR=\(configurationBuildDirectory.path)",
    ])
    for key in buildSettings.keys.sorted() {
        guard let value = buildSettings[key] else {
            continue
        }
        arguments.append("\(key)=\(value)")
    }
    arguments.append(action)
    try run(
        "xcodebuild",
        arguments
    )
}

func buildPhoneDevice(configuration: String) throws {
    let team = try developmentTeamFromEnvironment()
    try buildPhoneDevice(
        configuration: configuration,
        developmentTeam: team,
        shouldGenerateProject: true
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
    developmentTeam: String,
    shouldGenerateProject: Bool
) throws {
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
        buildSettings: [
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": developmentTeam,
        ]
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

private let wireGuardGoBridgeSourcePath: URL =
    repoRoot
    .appendingPathComponent("Tuist", isDirectory: true)
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("checkouts", isDirectory: true)
    .appendingPathComponent("wireguard-apple", isDirectory: true)
    .appendingPathComponent("Sources", isDirectory: true)
    .appendingPathComponent("WireGuardKitGo", isDirectory: true)

private let wireGuardGoBridgeLibraryDirectory: URL =
    repoRoot
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("vendor", isDirectory: true)

private let wireGuardGoBridgeTempDirectory: URL =
    repoRoot
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("vendor-temp", isDirectory: true)

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

struct XcodeDevice: Decodable {
    let simulator: Bool
    let available: Bool
    let platform: String
    let identifier: String
    let name: String
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
    try run("swift", swiftTestArguments())
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

func auditLogging() throws {
    try run(
        "swift",
        ["run", "--package-path", toolsPackageDirectory.path, "LoggingAudit"]
    )
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
    let analyzeDirectory = buildDirectory.appendingPathComponent("Analyze")
    try fileManager.createDirectory(at: analyzeDirectory, withIntermediateDirectories: true)
    let compilerLog = analyzeDirectory.appendingPathComponent("swiftlint-xcodebuild.log")
    let status = try runWritingOutput(
        "xcodebuild",
        [
            "-workspace",
            "CellTunnel.xcworkspace",
            "-scheme",
            "CellTunnelAgent",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS",
            "-derivedDataPath",
            analyzeDirectory.appendingPathComponent("SwiftLintDerivedData").path,
        ] + xcodeBuildCacheArguments(.disabled) + [
            "clean",
            "build",
        ],
        outputURL: compilerLog
    )
    guard status == 0 else {
        throw ToolError.failure("xcodebuild compiler-log build failed with status \(status)")
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

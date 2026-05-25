import Foundation

func generateProject() throws {
    try generateTypedIPC()
    try requireTool("tuist")
    if try projectGenerationIsCurrent() {
        return
    }
    let team = try signingConfig().developmentTeam
    let environment = [
        "DEVELOPMENT_TEAM": team,
        "TUIST_DEVELOPMENT_TEAM": team,
    ]
    try run("tuist", ["install"], environment: environment)
    try run("tuist", ["generate", "--no-open"], environment: environment)
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
    let team = try signingConfig().developmentTeam.trimmingCharacters(in: .whitespaces)
    parts.append("team:\(team)")
    for source in projectGenerationSources {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let modificationDate = attributes[.modificationDate] as? Date ?? Date.distantPast
        let size = attributes[.size] as? Int ?? 0
        parts.append("\(source.lastPathComponent):\(modificationDate.timeIntervalSince1970):\(size)")
    }
    return parts.joined(separator: "|")
}

func generateTypedIPC() throws {
    let stagingDirectory = try makeTemporaryDirectory(name: "GeneratedStaging")
    defer {
        try? fileManager.removeItem(at: stagingDirectory)
    }

    let swiftStagingDirectory = stagingDirectory.appendingPathComponent("swift")
    try generateSwiftTypedIPC(outputDirectory: swiftStagingDirectory)
    try replaceDirectory(at: swiftGeneratedDirectory, withItemAt: swiftStagingDirectory)
}

func generateSwiftTypedIPC(outputDirectory: URL) throws {
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try run(
        "swift",
        [
            "package",
            "--allow-writing-to-package-directory",
            "generate-grpc-code-from-protos",
            "--access-level",
            "public",
            "--file-naming",
            "dropPath",
            "--import-path",
            protoDirectory.path,
            "--output-path",
            outputDirectory.path,
            "--",
            swiftControlProtoPath.path,
        ]
    )
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
    let config = try signingConfig()
    try buildPhoneDevice(configuration: configuration, signing: config, shouldGenerateProject: true)
}

func buildPhoneDevice(
    configuration: String,
    signing config: SigningConfig,
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
        xcodebuildOptions: ["-allowProvisioningUpdates"],
        buildSettings: [
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": config.developmentTeam,
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
    try generateTypedIPC()
    try run("swift", swiftTestArguments())
}

func lintProject() throws {
    try generateTypedIPC()
    try lintSwiftProject()
}

func lintSwiftProject() throws {
    try requireTool("swift-format")
    try requireTool("swiftlint")
    try run(
        "swift-format",
        [
            "lint",
            "--configuration",
            ".swift-format",
            "--recursive",
            "--strict",
            "Apps",
            "Sources",
            "Tests",
            "Tools/CellTunnelCtl",
            "Tools/CellTunnelDev",
            "Tools/LoggingAudit",
            "Tools/cell-tunnel-dev.swift",
            "Tools/Package.swift",
            "Package.swift",
            "Project.swift",
            "Tuist.swift",
            "Tuist/Package.swift",
        ]
    )
    try run("swiftlint", ["lint", "--strict"])
}

func formatProject() throws {
    try generateTypedIPC()
    try formatSwiftProject()
}

func formatSwiftProject() throws {
    try requireTool("swift-format")
    try run(
        "swift-format",
        [
            "format",
            "--configuration",
            ".swift-format",
            "--recursive",
            "--in-place",
            "Apps",
            "Sources",
            "Tests",
            "Tools/CellTunnelCtl",
            "Tools/CellTunnelDev",
            "Tools/LoggingAudit",
            "Tools/cell-tunnel-dev.swift",
            "Tools/Package.swift",
            "Package.swift",
            "Project.swift",
            "Tuist.swift",
            "Tuist/Package.swift",
        ]
    )
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
        scheme: "CellTunnelMac",
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
            "CellTunnelMac",
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

func runMacApp() throws {
    try buildProject(target: .mac, configuration: "Debug")
    let appPath = productsDirectory.appendingPathComponent("Debug/macosx/CellTunnelMac.app")
    guard fileManager.fileExists(atPath: appPath.path) else {
        throw ToolError.failure("built app not found: \(appPath.path)")
    }

    _ = try? capture("pkill", ["-x", "CellTunnelMac"])
    try run(
        "open",
        ["-n", appPath.path],
        environment: ["CELL_TUNNEL_ROOT": repoRoot.path]
    )
}

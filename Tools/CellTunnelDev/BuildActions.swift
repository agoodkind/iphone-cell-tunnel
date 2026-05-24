import Foundation

func generateProject() throws {
    try generateTypedIPC()
    try requireTool("tuist")
    try run("tuist", ["install"])
    try run("tuist", ["generate", "--no-open"])
}

func buildProject(configuration: String) throws {
    try generateProject()
    try lintSwiftProject()
    try lintGoProject()
    try auditLogging()
    try auditGoProject()
    let config = try signingConfig()
    try requireSigningIdentity(config)
    try buildSwiftProduct("celltunnelctl")
    try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
    try installSwiftExecutable(productName: "celltunnelctl", outputName: "celltunnelctl")
    try runGoMake("build")
    try buildScheme(
        scheme: "CellTunnelMac",
        configuration: configuration,
        destination: "platform=macOS",
        platformName: macOSPlatformName
    )
    try buildScheme(
        scheme: "CellTunnelPhone",
        configuration: configuration,
        destination: ProcessInfo.processInfo.environment["IOS_SIMULATOR_DESTINATION"]
            ?? "generic/platform=iOS Simulator",
        platformName: iOSSimulatorPlatformName
    )
    try buildPhoneDevice(
        configuration: configuration,
        signing: config,
        shouldGenerateProject: false
    )
    try packageMacBundle(configuration: configuration, signing: config)
    try signMacProducts(configuration: configuration, signing: config)
}

func generateTypedIPC() throws {
    try requireTool("protoc")
    try requireTool("protoc-gen-go")
    try requireTool("protoc-gen-go-grpc")
    let stagingDirectory = try makeTemporaryDirectory(name: "GeneratedStaging")
    defer {
        try? fileManager.removeItem(at: stagingDirectory)
    }

    let swiftStagingDirectory = stagingDirectory.appendingPathComponent("swift")
    let goStagingRoot = stagingDirectory.appendingPathComponent("go")
    let goStagingDirectory = goStagingRoot.appendingPathComponent("internal/controlv1")

    try generateSwiftTypedIPC(outputDirectory: swiftStagingDirectory)
    try generateGoTypedIPC(outputDirectory: goStagingRoot)

    guard fileManager.fileExists(atPath: goStagingDirectory.path) else {
        throw ToolError.failure(
            "generated Go control sources not found: \(goStagingDirectory.path)")
    }

    try replaceDirectory(at: swiftGeneratedDirectory, withItemAt: swiftStagingDirectory)
    try replaceDirectory(at: goControlGeneratedDirectory, withItemAt: goStagingDirectory)
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

func generateGoTypedIPC(outputDirectory: URL) throws {
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try run(
        "protoc",
        [
            "--proto_path=\(protoDirectory.path)",
            "--go_out=module=celltunnel/daemon:\(outputDirectory.path)",
            "--go-grpc_out=module=celltunnel/daemon:\(outputDirectory.path)",
            swiftControlProtoPath.path,
        ]
    )
}

func buildSwiftProduct(_ productName: String) throws {
    try run("swift", ["build", "--product", productName])
}

func installSwiftExecutable(productName: String, outputName: String) throws {
    let binPathResult = try capture("swift", ["build", "--show-bin-path"], echoOutput: false)
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
    try run("swift", ["test"])
    try runGoMake("test")
}

func lintProject() throws {
    try generateTypedIPC()
    try lintSwiftProject()
    try lintGoProject()
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
    try formatGoProject()
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

func formatGoProject() throws {
    try runGoMake("fmt")
}

func lintGoProject() throws {
    try runGoMake("lint")
}

func auditLogging() throws {
    try run(
        "swift",
        ["run", "--package-path", toolsPackageDirectory.path, "LoggingAudit"]
    )
}

func auditGoProject() throws {
    try runGoMake("build-check")
}
func analyzeProject() throws {
    try requireTool("swiftlint")
    try requireTool("periphery")
    try generateProject()
    try xcodeAnalyze()
    try swiftLintAnalyze()
    try run("periphery", ["scan", "--config", ".periphery.yml"])
    try analyzeGoProject()
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

func analyzeGoProject() throws {
    try runGoMake("lint-deadcode")
    try runGoMake("staticcheck-extra")
}

func cleanProject() throws {
    let paths = [
        buildDirectory,
        productsDirectory,
        repoRoot.appendingPathComponent(".build"),
        repoRoot.appendingPathComponent("Tools/.build"),
        repoRoot.appendingPathComponent("CellTunnel.xcodeproj"),
        repoRoot.appendingPathComponent("CellTunnel.xcworkspace"),
        repoRoot.appendingPathComponent("Daemon/celltunneld"),
    ]

    for path in paths where fileManager.fileExists(atPath: path.path) {
        try fileManager.removeItem(at: path)
    }
}

func runGoMake(_ target: String) throws {
    try run(
        "make",
        ["-C", daemonDirectory.path, target],
        environment: goMakeEnvironment()
    )
}

func goMakeEnvironment() -> [String: String] {
    guard ProcessInfo.processInfo.environment["GO_MK_DEV_DIR"] == nil else {
        return [:]
    }

    let configuredDirectory = ProcessInfo.processInfo.environment["GO_MAKEFILE_DIR"]
    if let configuredDirectory, !configuredDirectory.isEmpty {
        return ["GO_MK_DEV_DIR": configuredDirectory]
    }

    let localDirectory = "\(NSHomeDirectory())/Sites/go-makefile"
    if fileManager.fileExists(atPath: localDirectory) {
        return ["GO_MK_DEV_DIR": localDirectory]
    }

    return [:]
}

func runMacApp() throws {
    try buildProject(configuration: "Debug")
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

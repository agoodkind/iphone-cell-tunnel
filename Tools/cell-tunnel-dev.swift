#!/usr/bin/env swift

import Foundation

enum ToolError: Error, CustomStringConvertible {
    case usage(String)
    case failure(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .failure(let message):
            return message
        }
    }
}

struct CommandResult {
    let status: Int32
    let output: String
}

let fileManager = FileManager.default
let repoRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath).standardizedFileURL
let productsDirectory = repoRoot.appendingPathComponent("Products")
let buildDirectory = repoRoot.appendingPathComponent("build")
let derivedDataDirectory = buildDirectory.appendingPathComponent("DerivedData")
let daemonDirectory = repoRoot.appendingPathComponent("Daemon")

func printHelp() {
    print(
        """
        usage: swift Tools/cell-tunnel-dev.swift <command>

        commands:
          help        Show this help text.
          generate    Install Tuist dependencies and generate CellTunnel.xcworkspace.
          build       Generate and build iOS, macOS, SwiftPM tooling, and the Go daemon.
          test        Run SwiftPM tests and Go daemon tests.
          lint        Run Swift and Go lint gates.
          format      Format Swift and Go sources.
          log-audit   Run the SwiftSyntax logging audit.
          go-audit    Run Go vet, vuln, deadcode, and staticcheck-extra gates.
          audit       Run lint, log-audit, and go-audit.
          analyze     Run Xcode analyze, SwiftLint analyze, Periphery, and Go analyzers.
          clean       Remove build and product outputs.
          run         Build and launch the macOS app.
        """
    )
}

func run(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: URL = repoRoot
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = mergedEnvironment(environment)

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let renderedCommand = ([executable] + arguments).joined(separator: " ")
        throw ToolError.failure("\(renderedCommand) failed with status \(process.terminationStatus)")
    }
}

func capture(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: URL = repoRoot
) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = workingDirectory

    process.environment = mergedEnvironment(environment)

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    try process.run()
    process.waitUntilExit()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    if !output.isEmpty {
        print(output, terminator: "")
    }

    return CommandResult(status: process.terminationStatus, output: output)
}

func runWritingOutput(
    _ executable: String,
    _ arguments: [String],
    outputURL: URL,
    environment: [String: String] = [:]
) throws -> Int32 {
    fileManager.createFile(atPath: outputURL.path, contents: nil)
    let outputFile = try FileHandle(forWritingTo: outputURL)
    defer {
        try? outputFile.close()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = repoRoot
    process.environment = mergedEnvironment(environment)
    process.standardOutput = outputFile
    process.standardError = outputFile

    try process.run()
    process.waitUntilExit()

    return process.terminationStatus
}

func requireTool(_ name: String) throws {
    let result = try capture("which", [name])
    guard result.status == 0 else {
        throw ToolError.failure("required tool not found: \(name)")
    }
}

func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
    var processEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in overrides {
        processEnvironment[key] = value
    }
    return processEnvironment
}

func generateProject() throws {
    try requireTool("tuist")
    try run("tuist", ["install"])
    try run("tuist", ["generate", "--no-open"])
}

func buildProject(configuration: String) throws {
    try lintProject()
    try auditLogging()
    try auditGoProject()
    try generateProject()
    try run("swift", ["build", "--product", "LoggingAudit"])
    try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
    try runGoMake("build")
    try buildScheme(
        scheme: "CellTunnelMac",
        configuration: configuration,
        destination: "platform=macOS"
    )
    try buildScheme(
        scheme: "CellTunnelPhone",
        configuration: configuration,
        destination: ProcessInfo.processInfo.environment["IOS_SIMULATOR_DESTINATION"]
            ?? "generic/platform=iOS Simulator"
    )
}

func buildScheme(
    scheme: String,
    configuration: String,
    destination: String,
    action: String = "build"
) throws {
    try run(
        "xcodebuild",
        [
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
            action,
        ]
    )
}

func testProject() throws {
    try run("swift", ["test"])
    try runGoMake("test")
}

func lintProject() throws {
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
            "Tools",
            "Package.swift",
            "Project.swift",
            "Tuist.swift",
            "Tuist/Package.swift",
        ]
    )
    try run("swiftlint", ["lint", "--strict"])
}

func formatProject() throws {
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
            "Tools",
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
    try run("swift", ["run", "LoggingAudit"])
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
        action: "analyze"
    )
    try buildScheme(
        scheme: "CellTunnelPhone",
        configuration: "Debug",
        destination: ProcessInfo.processInfo.environment["IOS_SIMULATOR_DESTINATION"]
            ?? "generic/platform=iOS Simulator",
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

    if let configuredDirectory = ProcessInfo.processInfo.environment["GO_MAKEFILE_DIR"], !configuredDirectory.isEmpty {
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

func main() throws {
    let command = CommandLine.arguments.dropFirst().first ?? "help"
    switch command {
    case "help":
        printHelp()
    case "generate":
        try generateProject()
    case "build":
        let configuration = CommandLine.arguments.dropFirst(2).first ?? "Debug"
        try buildProject(configuration: configuration)
    case "test":
        try testProject()
    case "lint":
        try lintProject()
    case "format":
        try formatProject()
    case "log-audit":
        try auditLogging()
    case "go-audit":
        try auditGoProject()
    case "audit":
        try lintProject()
        try auditLogging()
        try auditGoProject()
    case "analyze":
        try analyzeProject()
    case "clean":
        try cleanProject()
    case "run":
        try runMacApp()
    default:
        throw ToolError.usage("unknown command: \(command)")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

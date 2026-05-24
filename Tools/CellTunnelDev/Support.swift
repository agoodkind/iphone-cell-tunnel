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

var fileManager: FileManager {
    FileManager.default
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
let toolsPackageDirectory = repoRoot.appendingPathComponent("Tools")
let productsDirectory = repoRoot.appendingPathComponent("Products")
let buildDirectory = repoRoot.appendingPathComponent("build")
let derivedDataDirectory = buildDirectory.appendingPathComponent("DerivedData")
let daemonDirectory = repoRoot.appendingPathComponent("Daemon")
let protoDirectory = repoRoot.appendingPathComponent("Protos")
let swiftGeneratedDirectory = repoRoot.appendingPathComponent("Sources/CellTunnelCore/Generated")
let swiftControlProtoPath = protoDirectory.appendingPathComponent(
    "io/goodkind/celltunnel/control/v1/control.proto")
let goControlGeneratedDirectory = daemonDirectory.appendingPathComponent("internal/controlv1")
let signingConfigURL = repoRoot.appendingPathComponent("config/signing.env")
let defaultDeveloperIDIdentity = "Developer ID Application: Alex Goodkind (H3BMXM4W7H)"
let defaultDevelopmentTeam = "H3BMXM4W7H"
let defaultBundleIdentifierPrefix = "io.goodkind"
let defaultNotaryProfile = "cell-tunnel-notary"
let daemonLaunchDaemonPlistName = "io.goodkind.celltunneld.plist"
let macOSPlatformName = "macosx"
let iOSDevicePlatformName = "iphoneos"
let iOSSimulatorPlatformName = "iphonesimulator"
let phoneBundleIdentifier = "io.goodkind.CellTunnelPhone"
let macActivationArgument = "--cell-tunnel-activate-helper"
let autoCreatedSimulatorNamePrefix = "CellTunnelPhone Auto"

enum ActivationTarget: String, CaseIterable {
    case mac
    case iphone
    case iphoneSimulator = "iphone-simulator"
}

let activationTargetUsage = ActivationTarget.allCases.map(\.rawValue).joined(separator: "|")

func run(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: URL = repoRoot,
    failureMessage: String? = nil
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = mergedEnvironment(environment)

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let renderedCommand = failureMessage ?? ([executable] + arguments).joined(separator: " ")
        throw ToolError.failure(
            "\(renderedCommand) failed with status \(process.terminationStatus)")
    }
}

func capture(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: URL = repoRoot,
    echoOutput: Bool = true
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
    if echoOutput, !output.isEmpty {
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
    let result = try capture("which", [name], echoOutput: false)
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

func copyReplacingItem(at source: URL, to destination: URL) throws {
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: source, to: destination)
}

func replaceDirectory(at destination: URL, withItemAt source: URL) throws {
    if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        return
    }

    try fileManager.moveItem(at: source, to: destination)
}

func makeTemporaryDirectory(name: String) throws -> URL {
    let stagingParentDirectory = buildDirectory.appendingPathComponent(name)
    let directory = stagingParentDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func xcodeConfigurationBuildDirectory(configuration: String, platformName: String) -> URL {
    productsDirectory.appendingPathComponent(configuration).appendingPathComponent(platformName)
}

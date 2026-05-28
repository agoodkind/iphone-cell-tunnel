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
let macOSPlatformName = "macosx"
let iOSDevicePlatformName = "iphoneos"
let iOSSimulatorPlatformName = "iphonesimulator"
let phoneBundleIdentifier = "io.goodkind.CellTunnelPhone"
let phoneActivationArgument = "--cell-tunnel-start-relay"
let phoneListenerPortArgument = "--cell-tunnel-port"
let autoCreatedSimulatorNamePrefix = "CellTunnelPhone Auto"

enum ActivationTarget: String, CaseIterable {
    case iphone
    case iphoneSimulator = "iphone-simulator"
}

enum XcodeBuildCacheMode {
    case enabled
    case disabled
}

let activationTargetUsage = ActivationTarget.allCases.map(\.rawValue).joined(separator: "|")

func environmentArguments(_ key: String) -> [String] {
    let environmentValue = ProcessInfo.processInfo.environment[key] ?? ""
    return environmentValue.split(whereSeparator: \.isWhitespace).map(String.init)
}

func swiftBuildArguments(_ additionalArguments: [String]) -> [String] {
    var arguments = ["build"]
    arguments.append(contentsOf: environmentArguments("SWIFT_MK_SWIFTPM_CACHE_ARGS"))
    arguments.append(contentsOf: additionalArguments)
    return arguments
}

func swiftTestArguments(_ additionalArguments: [String] = []) -> [String] {
    var arguments = ["test"]
    arguments.append(contentsOf: environmentArguments("SWIFT_MK_SWIFTPM_CACHE_ARGS"))
    arguments.append(contentsOf: additionalArguments)
    return arguments
}

func xcodeBuildCacheArguments(_ mode: XcodeBuildCacheMode) -> [String] {
    switch mode {
    case .enabled:
        return environmentArguments("SWIFT_MK_XCODEBUILD_ARGS")
    case .disabled:
        return environmentArguments("SWIFT_MK_XCODEBUILD_NO_CACHE_ARGS")
    }
}

private let developmentTeamConfigPath = repoRoot.appendingPathComponent("config/signing.env")

func developmentTeamFromEnvironment() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    for key in ["TUIST_DEVELOPMENT_TEAM", "DEVELOPMENT_TEAM"] {
        if let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value
        }
    }
    if let teamFromFile = try developmentTeamFromConfigFile() {
        return teamFromFile
    }
    throw ToolError.failure(
        """
        DEVELOPMENT_TEAM (or TUIST_DEVELOPMENT_TEAM) must be set in the environment, \
        or DEVELOPMENT_TEAM defined in \(developmentTeamConfigPath.path)
        """
    )
}

private func developmentTeamFromConfigFile() throws -> String? {
    guard fileManager.fileExists(atPath: developmentTeamConfigPath.path) else {
        return nil
    }
    let contents = try String(contentsOf: developmentTeamConfigPath, encoding: .utf8)
    for rawLine in contents.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue
        }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        guard key == "DEVELOPMENT_TEAM" else {
            continue
        }
        let value = String(parts[1])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !value.isEmpty else {
            continue
        }
        return value
    }
    return nil
}

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

@discardableResult
func runBestEffort(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: URL = repoRoot
) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = mergedEnvironment(environment)

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return 127
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

func printToolOutput(_ message: String) {
    print(message)
}

func xcodeConfigurationBuildDirectory(configuration: String, platformName: String) -> URL {
    productsDirectory.appendingPathComponent(configuration).appendingPathComponent(platformName)
}

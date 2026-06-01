import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .build)
private let keyValuePairComponentCount = 2
private let commandNotFoundExitStatus: Int32 = 127

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
let macCatalystPlatformName = "maccatalyst"
let phoneBundleIdentifier = "io.goodkind.CellTunnelPhone"
let phoneActivationArgument = "--cell-tunnel-start-relay"
let phoneListenerPortArgument = "--cell-tunnel-port"
let autoCreatedSimulatorNamePrefix = "CellTunnelPhone Auto"

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

private let developmentTeamLocalConfigPath = repoRoot.appendingPathComponent(
    "Config/local.xcconfig")

func developmentTeamFromEnvironment() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    for key in ["TUIST_DEVELOPMENT_TEAM", "DEVELOPMENT_TEAM"] {
        if let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value
        }
    }
    if let teamFromFile = try developmentTeamFromLocalXcconfig() {
        return teamFromFile
    }
    throw ToolError.failure(
        """
        DEVELOPMENT_TEAM (or TUIST_DEVELOPMENT_TEAM) must be set in the environment, \
        or DEVELOPMENT_TEAM defined in \(developmentTeamLocalConfigPath.path)
        """
    )
}

private func developmentTeamFromLocalXcconfig() throws -> String? {
    guard fileManager.fileExists(atPath: developmentTeamLocalConfigPath.path) else {
        return nil
    }
    let contents = try String(contentsOf: developmentTeamLocalConfigPath, encoding: .utf8)
    for rawLine in contents.components(separatedBy: .newlines) {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("#") {
            continue
        }
        if let semicolon = line.firstIndex(of: ";") {
            line = String(line[..<semicolon]).trimmingCharacters(in: .whitespaces)
        }
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == keyValuePairComponentCount else {
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

private let signingEnvironmentLocalPath = repoRoot.appendingPathComponent(
    "Config/local.signing.env")

// xcodebuild flags that authenticate automatic signing with an App Store Connect
// API key, or an empty array when no key is configured. With no key the iOS
// device build falls back to the interactive Xcode account, so this coexists with
// GUI signing. Each value is read from the process environment first, then from
// Config/local.signing.env (gitignored). The private key is supplied either as a
// .p8 path in APPLE_NOTARY_KEY_PATH or as base64 in APPLE_NOTARY_KEY_BASE64, which
// is written to a 0600 temp .p8. No key id, issuer id, key path, or key bytes are
// ever logged.
func appStoreConnectAuthArguments() throws -> [String] {
    let keyID = signingEnvironmentValue("APPLE_NOTARY_KEY_ID")
    let issuerID = signingEnvironmentValue("APPLE_NOTARY_ISSUER_ID")
    guard let keyID, let issuerID else {
        if keyID != nil || issuerID != nil {
            printToolOutput(
                """
                App Store Connect API key auth skipped: set both \
                APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID
                """
            )
        }
        return []
    }
    guard let keyPath = try appStoreConnectKeyPath(keyID: keyID) else {
        printToolOutput(
            """
            App Store Connect API key auth skipped: set \
            APPLE_NOTARY_KEY_PATH or APPLE_NOTARY_KEY_BASE64
            """
        )
        return []
    }
    printToolOutput("App Store Connect API key auth enabled for automatic signing")
    return [
        "-authenticationKeyID", keyID,
        "-authenticationKeyIssuerID", issuerID,
        "-authenticationKeyPath", keyPath,
    ]
}

// Reads a signing value from the process environment first, then from
// Config/local.signing.env, returning nil when unset or empty.
private func signingEnvironmentValue(_ key: String) -> String? {
    let environment = ProcessInfo.processInfo.environment
    let value = environment[key]?.trimmingCharacters(in: .whitespaces)
    if let value, !value.isEmpty {
        return value
    }
    return signingEnvironmentFileValue(key)
}

private func signingEnvironmentFileValue(_ key: String) -> String? {
    guard fileManager.fileExists(atPath: signingEnvironmentLocalPath.path) else {
        return nil
    }
    let contents: String
    do {
        contents = try String(contentsOf: signingEnvironmentLocalPath, encoding: .utf8)
    } catch {
        logger.error(
            """
            failed reading signing env file \
            details=\(error.localizedDescription, privacy: .public) recovery=skip-file
            """
        )
        return nil
    }
    for rawLine in contents.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == keyValuePairComponentCount,
            String(parts[0]).trimmingCharacters(in: .whitespaces) == key
        else {
            continue
        }
        let value = String(parts[1])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if value.isEmpty {
            continue
        }
        return value
    }
    return nil
}

// Resolves the .p8 path from APPLE_NOTARY_KEY_PATH (tilde expanded) or by decoding
// APPLE_NOTARY_KEY_BASE64 to a 0600 temp file named AuthKey_<keyID>.p8.
private func appStoreConnectKeyPath(keyID: String) throws -> String? {
    logger.debug("resolving App Store Connect API key path")
    if let rawPath = signingEnvironmentValue("APPLE_NOTARY_KEY_PATH") {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard fileManager.fileExists(atPath: expanded) else {
            throw ToolError.failure(
                "APPLE_NOTARY_KEY_PATH is set but no file exists at the resolved path")
        }
        return expanded
    }
    guard let base64 = signingEnvironmentValue("APPLE_NOTARY_KEY_BASE64") else {
        return nil
    }
    guard let keyData = Data(base64Encoded: base64) else {
        throw ToolError.failure("APPLE_NOTARY_KEY_BASE64 is not valid base64")
    }
    let destination = fileManager.temporaryDirectory
        .appendingPathComponent("AuthKey_\(keyID).p8")
    // Remove any stale file first so the key is created fresh with 0600 applied at
    // creation. This closes the window a write-then-chmod leaves open, and a file
    // owned by another user surfaces as a removeItem error rather than a stale key.
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    guard
        fileManager.createFile(
            atPath: destination.path,
            contents: keyData,
            attributes: [.posixPermissions: 0o600]
        )
    else {
        throw ToolError.failure(
            "failed to write the decoded App Store Connect key to a temp file")
    }
    return destination.path
}

func run(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: URL = repoRoot,
    failureMessage: String? = nil
) throws {
    logger.debug("run executable=\(executable, privacy: .public)")
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
    logger.debug("runBestEffort executable=\(executable, privacy: .public)")
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
        logger.error(
            """
            runBestEffort failed executable=\(executable, privacy: .public) \
            details=\(error.localizedDescription, privacy: .public) recovery=return-not-found-status
            """
        )
        return commandNotFoundExitStatus
    }
}

func capture(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: URL = repoRoot,
    echoOutput: Bool = true
) throws -> CommandResult {
    logger.debug("capture executable=\(executable, privacy: .public)")
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
        FileHandle.standardOutput.write(Data(output.utf8))
    }

    return CommandResult(status: process.terminationStatus, output: output)
}

func runWritingOutput(
    _ executable: String,
    _ arguments: [String],
    outputURL: URL,
    environment: [String: String] = [:]
) throws -> Int32 {
    logger.debug("runWritingOutput executable=\(executable, privacy: .public)")
    fileManager.createFile(atPath: outputURL.path, contents: nil)
    let outputFile = try FileHandle(forWritingTo: outputURL)
    defer {
        do {
            try outputFile.close()
        } catch {
            logger.error(
                """
                runWritingOutput failed closing output file \
                details=\(error.localizedDescription, privacy: .public) recovery=continue
                """
            )
        }
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
    logger.debug(
        "copyReplacingItem source=\(source.lastPathComponent, privacy: .public)")
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: source, to: destination)
}

func printToolOutput(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

func xcodeConfigurationBuildDirectory(configuration: String, platformName: String) -> URL {
    productsDirectory.appendingPathComponent(configuration).appendingPathComponent(platformName)
}

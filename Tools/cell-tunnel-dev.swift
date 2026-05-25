#!/usr/bin/env swift
import Foundation

let forwardedArguments = Array(CommandLine.arguments.dropFirst())
let toolsPackageDirectoryName = "Tools"

func environmentArguments(_ key: String) -> [String] {
    let environmentValue = ProcessInfo.processInfo.environment[key] ?? ""
    return environmentValue.split(whereSeparator: \.isWhitespace).map(String.init)
}

func swiftBuildArguments(packagePath: String, additionalArguments: [String]) -> [String] {
    var arguments = ["swift", "build"]
    arguments.append(contentsOf: environmentArguments("SWIFT_MK_SWIFTPM_CACHE_ARGS"))
    arguments.append(contentsOf: ["--package-path", packagePath])
    arguments.append(contentsOf: additionalArguments)
    return arguments
}

func runToolBinary(_ executable: URL, arguments: [String], workingDirectory: URL) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = ProcessInfo.processInfo.environment
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let renderedCommand = ([executable.path] + arguments).joined(separator: " ")
        throw NSError(
            domain: "CellTunnelDevWrapper",
            code: Int(process.terminationStatus),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(renderedCommand) failed with status \(process.terminationStatus)"
            ]
        )
    }
}

do {
    let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let toolsPackageDirectory = currentDirectoryURL.appendingPathComponent(
        toolsPackageDirectoryName)
    let buildProcess = Process()
    buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    buildProcess.arguments = swiftBuildArguments(
        packagePath: toolsPackageDirectory.path,
        additionalArguments: ["--product", "CellTunnelDev"]
    )
    buildProcess.currentDirectoryURL = currentDirectoryURL
    buildProcess.environment = ProcessInfo.processInfo.environment
    try buildProcess.run()
    buildProcess.waitUntilExit()
    guard buildProcess.terminationStatus == 0 else {
        throw NSError(domain: "CellTunnelDevWrapper", code: Int(buildProcess.terminationStatus))
    }

    let binPathProcess = Process()
    let outputPipe = Pipe()
    binPathProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    binPathProcess.arguments = swiftBuildArguments(
        packagePath: toolsPackageDirectory.path,
        additionalArguments: ["--show-bin-path"]
    )
    binPathProcess.currentDirectoryURL = currentDirectoryURL
    binPathProcess.environment = ProcessInfo.processInfo.environment
    binPathProcess.standardOutput = outputPipe
    binPathProcess.standardError = outputPipe
    try binPathProcess.run()
    binPathProcess.waitUntilExit()

    let binPathData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let binPath =
        String(data: binPathData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard binPathProcess.terminationStatus == 0, !binPath.isEmpty else {
        throw NSError(domain: "CellTunnelDevWrapper", code: Int(binPathProcess.terminationStatus))
    }

    let toolBinary = URL(fileURLWithPath: binPath).appendingPathComponent("CellTunnelDev")
    try runToolBinary(
        toolBinary, arguments: forwardedArguments, workingDirectory: currentDirectoryURL)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("failed to start CellTunnelDev: \(error)\n".utf8))
    exit(1)
}

#!/usr/bin/env swift

import Foundation

// Keep these constants in sync with Sources/CellTunnelCore/AgentControlXPC.swift
// (agentMachServiceName, agentBundleIdentifier, agentBinaryName).
let AGENT_MACH_SERVICE_NAME = "io.goodkind.celltunnel-agent"
let AGENT_EXECUTABLE_NAME = "CellTunnelAgent"
let AGENT_BUNDLE_ID = "io.goodkind.CellTunnel.Agent"

struct GenerateFailure: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) throws -> Never {
    throw GenerateFailure(description: "GenerateAgentLaunchAgentPlist failed: \(message)")
}

func reportError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else {
        try fail("usage: GenerateAgentLaunchAgentPlist.swift <template-path> <output-path>")
    }
    let templatePath = arguments[1]
    let outputPath = arguments[2]

    guard FileManager.default.fileExists(atPath: templatePath) else {
        try fail("missing template file: \(templatePath)")
    }

    let outputDirectory = (outputPath as NSString).deletingLastPathComponent
    var isDirectory: ObjCBool = false
    let outputDirectoryExists = FileManager.default.fileExists(
        atPath: outputDirectory,
        isDirectory: &isDirectory
    )
    if !outputDirectoryExists || !isDirectory.boolValue {
        try FileManager.default.createDirectory(
            atPath: outputDirectory,
            withIntermediateDirectories: true
        )
    }

    let templateURL = URL(fileURLWithPath: templatePath)
    var contents = try String(contentsOf: templateURL, encoding: .utf8)

    let replacements: [(token: String, value: String)] = [
        ("@@AGENT_MACH_SERVICE_NAME@@", AGENT_MACH_SERVICE_NAME),
        ("@@AGENT_EXECUTABLE_NAME@@", AGENT_EXECUTABLE_NAME),
        ("@@AGENT_BUNDLE_ID@@", AGENT_BUNDLE_ID),
    ]
    for replacement in replacements {
        contents = contents.replacingOccurrences(of: replacement.token, with: replacement.value)
    }

    if contents.contains("@@") {
        try fail("unsubstituted token found in rendered plist at \(outputPath)")
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    try contents.write(to: outputURL, atomically: true, encoding: .utf8)
} catch let failure as GenerateFailure {
    reportError(failure.description)
    exit(1)
} catch {
    reportError("GenerateAgentLaunchAgentPlist failed: \(error)")
    exit(1)
}

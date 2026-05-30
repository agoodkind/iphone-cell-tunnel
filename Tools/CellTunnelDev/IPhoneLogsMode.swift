//
//  IPhoneLogsMode.swift
//  CellTunnelDev
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let iPhoneLogsLogger = CellTunnelLog.logger(category: .build)
private let iPhoneLogsUsage = """
    usage: iphone-logs [--app | --simulator | --collect] [--device <udid>]
                       [--last <duration>] [--contains <text>]

    Reads iPhone or simulator logs.

    Default streams the full iPhone syslog over USB (live).
      --app         Stream the live iPhone syslog filtered to CellTunnelPhone.
      --simulator   Stream Mac-side log filtered to the io.goodkind.celltunnel
                    subsystem (simulator runs and Mac processes).
      --collect     Collect the device unified log and print the
                    io.goodkind.celltunnel subsystem with history (the live
                    syslog cannot show entries emitted before it attached). Uses
                    `sudo log collect`, so it needs an admin password.
      --device      Use a specific iPhone USB UDID (idevice_id -l). Defaults to
                    the first connected device.
      --last        Time range for --collect, in `log` duration form (default 30m).
      --contains    With --collect, only show lines whose message contains <text>.
      --predicate   With --collect, use this raw NSPredicate instead of the
                    io.goodkind.celltunnel subsystem default, to inspect system
                    subsystems (mDNSResponder, kernel, nesessionmanager) around an
                    event. --contains still ANDs onto it.

    Streaming modes run until Ctrl-C. --collect returns when the dump completes.
    """
private let unifiedLogDefaultDuration = "30m"
private let unifiedLogArchiveName = "celltunnel-device.logarchive"

// MARK: - Mode

private enum IPhoneLogsMode {
    case appFilteredDevice
    case fullDevice
    case simulator
    case unifiedDevice
}

private struct IPhoneLogsOptions {
    var mode: IPhoneLogsMode = .fullDevice
    var deviceOverride: String?
    var lastDuration = unifiedLogDefaultDuration
    var containsFilter: String?
    var rawPredicate: String?
}

// MARK: - Entry point

func runIPhoneLogs(_ arguments: [String]) throws {
    var options = IPhoneLogsOptions()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--app":
            try setIPhoneLogsMode(&options.mode, to: .appFilteredDevice)
        case "--simulator":
            try setIPhoneLogsMode(&options.mode, to: .simulator)
        case "--collect":
            try setIPhoneLogsMode(&options.mode, to: .unifiedDevice)
        case "--device":
            options.deviceOverride = try requireIPhoneLogsValue(&iterator, for: argument)
        case "--last":
            options.lastDuration = try requireIPhoneLogsValue(&iterator, for: argument)
        case "--contains":
            options.containsFilter = try requireIPhoneLogsValue(&iterator, for: argument)
        case "--predicate":
            options.rawPredicate = try requireIPhoneLogsValue(&iterator, for: argument)
        case "-h", "--help":
            FileHandle.standardOutput.write(Data((iPhoneLogsUsage + "\n").utf8))
            return
        default:
            throw ToolError.usage("unknown iphone-logs argument: \(argument)")
        }
    }
    try dispatchIPhoneLogs(options)
}

private func dispatchIPhoneLogs(_ options: IPhoneLogsOptions) throws {
    switch options.mode {
    case .simulator:
        try streamSimulatorLogs()
    case .fullDevice:
        try streamDeviceLogs(deviceOverride: options.deviceOverride, filterToApp: false)
    case .appFilteredDevice:
        try streamDeviceLogs(deviceOverride: options.deviceOverride, filterToApp: true)
    case .unifiedDevice:
        try collectAndShowUnifiedLog(
            deviceOverride: options.deviceOverride,
            lastDuration: options.lastDuration,
            containsFilter: options.containsFilter,
            rawPredicate: options.rawPredicate
        )
    }
}

// MARK: - Live streaming modes

private func streamSimulatorLogs() throws {
    let predicate = "subsystem == \"\(CellTunnelLog.subsystem)\""
    let arguments = [
        "stream",
        "--predicate",
        predicate,
        "--level",
        "debug",
    ]
    announceInvocation("log " + renderShellArguments(arguments))
    try run("log", arguments)
}

private func streamDeviceLogs(deviceOverride: String?, filterToApp: Bool) throws {
    try requireIDeviceSyslog()
    let udid = try resolveUSBDeviceUDID(override: deviceOverride)

    if filterToApp {
        let pipeline =
            "idevicesyslog -u \(shellQuote(udid)) "
            + "| grep --line-buffered -i -E 'CellTunnelPhone|io\\.goodkind\\.celltunnel'"
        announceInvocation(pipeline)
        try run("sh", ["-c", pipeline])
        return
    }

    let arguments = ["-u", udid]
    announceInvocation("idevicesyslog " + renderShellArguments(arguments))
    try run("idevicesyslog", arguments)
}

// MARK: - Unified-log collection

/// Collects the attached device's unified log into a temporary archive and prints
/// the io.goodkind.celltunnel subsystem entries it contains, optionally narrowed
/// to lines whose message contains a substring. The live syslog cannot show
/// entries emitted before it attached, so this is the way to read our own logging
/// after the fact, including a one-time error that set lastError.
private func collectAndShowUnifiedLog(
    deviceOverride: String?,
    lastDuration: String,
    containsFilter: String?,
    rawPredicate: String?
) throws {
    iPhoneLogsLogger.notice(
        "iphone-logs collecting unified log lastDuration=\(lastDuration, privacy: .public)")
    try requireIDeviceID()
    let udid = try resolveUSBDeviceUDID(override: deviceOverride)
    let archiveURL = fileManager.temporaryDirectory.appendingPathComponent(unifiedLogArchiveName)
    if fileManager.fileExists(atPath: archiveURL.path) {
        try fileManager.removeItem(at: archiveURL)
    }
    defer {
        cleanupUnifiedLogArchive(at: archiveURL)
    }

    let collectArguments = [
        "log", "collect",
        "--device-udid", udid,
        "--last", lastDuration,
        "--output", archiveURL.path,
    ]
    announceInvocation("sudo " + renderShellArguments(collectArguments))
    try run(
        "sudo",
        collectArguments,
        failureMessage: "sudo log collect failed (needs an admin password and a connected device)"
    )

    let predicate = unifiedLogPredicate(containsFilter: containsFilter, rawPredicate: rawPredicate)
    let showArguments = [
        "show", archiveURL.path,
        "--predicate", predicate,
        "--info", "--debug",
        "--style", "compact",
    ]
    announceInvocation("log " + renderShellArguments(showArguments))
    try run("log", showArguments)
}

private func unifiedLogPredicate(containsFilter: String?, rawPredicate: String?) -> String {
    var predicate = rawPredicate ?? "subsystem == \"\(CellTunnelLog.subsystem)\""
    if let containsFilter, !containsFilter.isEmpty {
        let escaped = containsFilter.replacingOccurrences(of: "\"", with: "\\\"")
        predicate += " AND composedMessage CONTAINS[c] \"\(escaped)\""
    }
    return predicate
}

private func cleanupUnifiedLogArchive(at archiveURL: URL) {
    guard fileManager.fileExists(atPath: archiveURL.path) else {
        return
    }
    do {
        try fileManager.removeItem(at: archiveURL)
    } catch {
        iPhoneLogsLogger.error(
            """
            iphone-logs temp archive cleanup failed \
            details=\(error.localizedDescription, privacy: .public) recovery=leave-archive
            """
        )
        FileHandle.standardError.write(
            Data("iphone-logs: failed to remove temp archive: \(error)\n".utf8))
    }
}

// MARK: - Tool and device resolution

private func requireIDeviceSyslog() throws {
    try requireLogTool("idevicesyslog")
}

private func requireIDeviceID() throws {
    try requireLogTool("idevice_id")
}

private func requireLogTool(_ name: String) throws {
    let result = try capture("which", [name], echoOutput: false)
    guard result.status == 0 else {
        throw ToolError.failure(
            "\(name) not found on PATH. Install with: brew install libimobiledevice")
    }
}

/// Resolves the iPhone USB UDID that idevicesyslog and `log collect --device-udid`
/// both expect, from an explicit override, the environment, or `idevice_id -l`.
private func resolveUSBDeviceUDID(override: String?) throws -> String {
    if let override, !override.isEmpty {
        return override
    }
    let environment = ProcessInfo.processInfo.environment
    for key in ["CELL_TUNNEL_IOS_DEVICE_UDID", "IOS_DEVICE_UDID"] {
        if let value = environment[key], !value.isEmpty {
            return value
        }
    }
    let result = try capture("idevice_id", ["-l"], echoOutput: false)
    guard result.status == 0 else {
        throw ToolError.failure("idevice_id -l failed to list connected devices")
    }
    let udid =
        result.output
        .split(whereSeparator: \.isNewline)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    guard !udid.isEmpty else {
        throw ToolError.failure("no USB-attached iPhone found via idevice_id -l")
    }
    return udid
}

// MARK: - Rendering helpers

private func announceInvocation(_ rendered: String) {
    let banner = "iphone-logs: running: \(rendered)\n"
    FileHandle.standardError.write(Data(banner.utf8))
}

private func requireIPhoneLogsValue(
    _ iterator: inout IndexingIterator<[String]>,
    for option: String
) throws -> String {
    guard let value = iterator.next() else {
        throw ToolError.usage("missing value for \(option)")
    }
    return value
}

private func setIPhoneLogsMode(_ mode: inout IPhoneLogsMode, to requested: IPhoneLogsMode) throws {
    guard mode == .fullDevice else {
        throw ToolError.usage("--app, --simulator, and --collect are mutually exclusive")
    }
    mode = requested
}

private func renderShellArguments(_ arguments: [String]) -> String {
    arguments.map(shellQuote).joined(separator: " ")
}

private func shellQuote(_ value: String) -> String {
    if value.allSatisfy({ character in
        character.isLetter || character.isNumber || character == "-" || character == "_"
            || character == "/" || character == "." || character == ":"
    }) {
        return value
    }
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

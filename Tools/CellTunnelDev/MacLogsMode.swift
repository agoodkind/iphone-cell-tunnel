//
//  MacLogsMode.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let macLogsLogger = CellTunnelLog.logger(category: .build)
private let macLogsDefaultDuration = "5m"
private let macLogsUsage = """
    usage: mac-logs [--stream] [--last <duration>] [--contains <text>]
                    [--predicate <NSPredicate>]

    Reads Mac-side io.goodkind.celltunnel logs: the CellTunnelAgent and the
    CellTunnelTunnelProvider packet-tunnel extension. Invokes `log` through the
    tool, which execs /usr/bin/log so the interactive zsh `log` builtin never
    shadows it.

    Default shows unified-log history for the last duration.
      --stream      Stream live instead of showing history. Runs until Ctrl-C.
      --last        History range for the default show mode, in `log` duration
                    form (default 5m).
      --contains    Only show lines whose message contains <text>.
      --predicate   Use this raw NSPredicate instead of the io.goodkind.celltunnel
                    subsystem default, to inspect system subsystems (nesessionmanager,
                    kernel) around an event. --contains still ANDs onto it.
    """

// MARK: - Mode

private enum MacLogsMode {
    case show
    case stream
}

// MARK: - MacLogsOptions

private struct MacLogsOptions {
    var mode: MacLogsMode = .show
    var lastDuration = macLogsDefaultDuration
    var containsFilter: String?
    var rawPredicate: String?
}

// MARK: - Entry point

/// Parses `mac-logs` arguments and dispatches to the history or live-stream mode.
func runMacLogs(_ arguments: [String]) throws {
    var options = MacLogsOptions()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--stream":
            options.mode = .stream
        case "--last":
            options.lastDuration = try requireMacLogsValue(&iterator, for: argument)
        case "--contains":
            options.containsFilter = try requireMacLogsValue(&iterator, for: argument)
        case "--predicate":
            options.rawPredicate = try requireMacLogsValue(&iterator, for: argument)
        case "-h", "--help":
            FileHandle.standardOutput.write(Data((macLogsUsage + "\n").utf8))
            return
        default:
            throw ToolError.usage("unknown mac-logs argument: \(argument)")
        }
    }
    try dispatchMacLogs(options)
}

private func dispatchMacLogs(_ options: MacLogsOptions) throws {
    let predicate = macLogsPredicate(
        containsFilter: options.containsFilter,
        rawPredicate: options.rawPredicate
    )
    switch options.mode {
    case .show:
        try showMacLogs(predicate: predicate, lastDuration: options.lastDuration)
    case .stream:
        try streamMacLogs(predicate: predicate)
    }
}

// MARK: - Show and stream

/// Prints unified-log history for the predicate over the last duration. This reads
/// the live system log store directly, so it shows entries emitted before the
/// command ran, which a live stream cannot.
private func showMacLogs(predicate: String, lastDuration: String) throws {
    macLogsLogger.notice(
        "mac-logs show lastDuration=\(lastDuration, privacy: .public)")
    let arguments = [
        "show",
        "--predicate", predicate,
        "--info", "--debug",
        "--style", "compact",
        "--last", lastDuration,
    ]
    announceMacLogsInvocation("log " + renderMacLogsArguments(arguments))
    try run("log", arguments)
}

/// Streams live log entries for the predicate until interrupted.
private func streamMacLogs(predicate: String) throws {
    macLogsLogger.notice("mac-logs stream starting")
    let arguments = [
        "stream",
        "--predicate", predicate,
        "--level", "debug",
        "--style", "compact",
    ]
    announceMacLogsInvocation("log " + renderMacLogsArguments(arguments))
    try run("log", arguments)
}

private func macLogsPredicate(containsFilter: String?, rawPredicate: String?) -> String {
    var predicate = rawPredicate ?? "subsystem == \"\(CellTunnelLog.subsystem)\""
    if let containsFilter, !containsFilter.isEmpty {
        let escaped = containsFilter.replacingOccurrences(of: "\"", with: "\\\"")
        predicate += " AND composedMessage CONTAINS[c] \"\(escaped)\""
    }
    return predicate
}

// MARK: - Rendering helpers

private func announceMacLogsInvocation(_ rendered: String) {
    let banner = "mac-logs: running: \(rendered)\n"
    FileHandle.standardError.write(Data(banner.utf8))
}

private func requireMacLogsValue(
    _ iterator: inout IndexingIterator<[String]>,
    for option: String
) throws -> String {
    guard let value = iterator.next() else {
        throw ToolError.usage("missing value for \(option)")
    }
    return value
}

private func renderMacLogsArguments(_ arguments: [String]) -> String {
    arguments.map(macLogsShellQuote).joined(separator: " ")
}

private func macLogsShellQuote(_ value: String) -> String {
    if value.allSatisfy({ character in
        character.isLetter || character.isNumber || character == "-" || character == "_"
            || character == "/" || character == "." || character == ":"
    }) {
        return value
    }
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

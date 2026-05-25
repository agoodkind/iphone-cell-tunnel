import CellTunnelLog
import Foundation

private let iPhoneLogsUsage = """
    usage: iphone-logs [--app] [--simulator] [--device <udid>]

    Streams iPhone or simulator logs.

    Default streams the full iPhone syslog over USB.
      --app         Filter the iPhone stream to lines mentioning CellTunnelPhone.
      --simulator   Stream Mac-side log filtered to the io.goodkind.celltunnel subsystem.
                    Catches simulator runs and any Mac process using the same subsystem.
      --device      Use a specific iPhone UDID. Defaults to the first connected device.

    Press Ctrl-C to stop.
    """

private enum IPhoneLogsMode {
    case fullDevice
    case appFilteredDevice
    case simulator
}

func runIPhoneLogs(_ arguments: [String]) throws {
    var mode: IPhoneLogsMode = .fullDevice
    var deviceOverride: String?

    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--app":
            guard mode != .simulator else {
                throw ToolError.usage("--app and --simulator are mutually exclusive")
            }
            mode = .appFilteredDevice
        case "--simulator":
            guard mode == .fullDevice else {
                throw ToolError.usage("--app and --simulator are mutually exclusive")
            }
            mode = .simulator
        case "--device":
            guard let value = iterator.next() else {
                throw ToolError.usage(iPhoneLogsUsage)
            }
            deviceOverride = value
        case "-h", "--help":
            print(iPhoneLogsUsage)
            return
        default:
            throw ToolError.usage("unknown iphone-logs argument: \(argument)")
        }
    }

    switch mode {
    case .simulator:
        try streamSimulatorLogs()
    case .fullDevice:
        try streamDeviceLogs(deviceOverride: deviceOverride, filterToApp: false)
    case .appFilteredDevice:
        try streamDeviceLogs(deviceOverride: deviceOverride, filterToApp: true)
    }
}

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
    let udid = try resolveDeviceUDID(override: deviceOverride)

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

private func requireIDeviceSyslog() throws {
    let result = try capture("which", ["idevicesyslog"], echoOutput: false)
    guard result.status == 0 else {
        throw ToolError.failure(
            "idevicesyslog not found on PATH. Install with: brew install libimobiledevice"
        )
    }
}

private func resolveDeviceUDID(override: String?) throws -> String {
    if let override, !override.isEmpty {
        return override
    }
    return try selectedPhoneDeviceIdentifier()
}

private func announceInvocation(_ rendered: String) {
    let banner = "iphone-logs: streaming with: \(rendered)\n"
    FileHandle.standardError.write(Data(banner.utf8))
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

import CellTunnelCore
import CellTunnelLog
import Foundation

enum InstallActions {}

private let installLogger = CellTunnelLog.logger(category: .build)

let defaultInstallParentDirectory = "/Applications/CellTunnel"
private let installAppOptionName = "--app"
private let installConfigOptionName = "--config"
private let installDestinationOptionName = "--destination"
private let openExecutablePath = "/usr/bin/open"
private let installCommandArgumentDropCount = 2
private let installOptionPairStride = 2

struct InstallMacOptions {
    let configuration: String
    let explicitSourceAppPath: String?
    let destinationParentPath: String
}

func parseInstallMacOptions() throws -> InstallMacOptions {
    let arguments = Array(CommandLine.arguments.dropFirst(installCommandArgumentDropCount))
    let usage = """
        usage: install-mac [\(installConfigOptionName) Debug|Release] \
        [\(installAppOptionName) <path>] [\(installDestinationOptionName) <dir>]
        """

    var configuration = "Debug"
    var explicitSourceAppPath: String?
    var destinationParentPath = defaultInstallParentDirectory

    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        let valueIndex = arguments.index(after: index)
        switch argument {
        case installConfigOptionName:
            guard valueIndex < arguments.endIndex else {
                throw ToolError.usage("missing value for \(installConfigOptionName). \(usage)")
            }
            let value = arguments[valueIndex]
            guard value == "Debug" || value == "Release" else {
                throw ToolError.usage(
                    "invalid \(installConfigOptionName) value: \(value). \(usage)")
            }
            configuration = value
            index = arguments.index(index, offsetBy: installOptionPairStride)
        case installAppOptionName:
            guard valueIndex < arguments.endIndex else {
                throw ToolError.usage("missing value for \(installAppOptionName). \(usage)")
            }
            explicitSourceAppPath = arguments[valueIndex]
            index = arguments.index(index, offsetBy: installOptionPairStride)
        case installDestinationOptionName:
            guard valueIndex < arguments.endIndex else {
                throw ToolError.usage(
                    "missing value for \(installDestinationOptionName). \(usage)")
            }
            destinationParentPath = arguments[valueIndex]
            index = arguments.index(index, offsetBy: installOptionPairStride)
        default:
            throw ToolError.usage("unknown install-mac argument: \(argument). \(usage)")
        }
    }

    return InstallMacOptions(
        configuration: configuration,
        explicitSourceAppPath: explicitSourceAppPath,
        destinationParentPath: destinationParentPath
    )
}

func runInstallMac(options: InstallMacOptions) throws {
    let sourceAppURL = try resolveInstallMacSourceURL(options: options)
    installLogger.notice(
        "install-mac source resolved path=\(sourceAppURL.path, privacy: .public)"
    )
    printToolOutput("source: \(sourceAppURL.path)")

    let destinationParentURL = URL(
        fileURLWithPath: (options.destinationParentPath as NSString).expandingTildeInPath,
        isDirectory: true
    )
    try fileManager.createDirectory(at: destinationParentURL, withIntermediateDirectories: true)

    let destinationAppURL = destinationParentURL.appendingPathComponent(agentAppBundleName)
    if fileManager.fileExists(atPath: destinationAppURL.path) {
        try fileManager.removeItem(at: destinationAppURL)
    }
    try fileManager.copyItem(at: sourceAppURL, to: destinationAppURL)
    installLogger.notice(
        """
        install-mac copied bundle source=\(sourceAppURL.path, privacy: .public) \
        destination=\(destinationAppURL.path, privacy: .public)
        """
    )
    printToolOutput("installed: \(destinationAppURL.path)")

    try launchInstalledAgent(at: destinationAppURL)
    printToolOutput(
        """
        agent launched; approve 'CellTunnel' in System Settings > General > Login Items \
        if prompted, then run: celltunnelctl start --config <path>
        """
    )
}

private func resolveInstallMacSourceURL(options: InstallMacOptions) throws -> URL {
    if let explicit = options.explicitSourceAppPath {
        let trimmed = explicit.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ToolError.usage("\(installAppOptionName) must not be empty")
        }
        let explicitURL = URL(
            fileURLWithPath: (trimmed as NSString).expandingTildeInPath
        )
        guard fileManager.fileExists(atPath: explicitURL.path) else {
            throw ToolError.failure(
                "install-mac: source bundle not found at \(explicitURL.path)")
        }
        return explicitURL
    }

    let defaultSource = xcodeConfigurationBuildDirectory(
        configuration: options.configuration,
        platformName: macOSPlatformName
    ).appendingPathComponent(agentAppBundleName)
    guard fileManager.fileExists(atPath: defaultSource.path) else {
        throw ToolError.failure(
            """
            install-mac: source bundle not found at \(defaultSource.path); \
            run `make build TARGET=mac CONFIG=\(options.configuration)` first
            """
        )
    }
    return defaultSource
}

private func launchInstalledAgent(at appURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: openExecutablePath)
    process.arguments = ["-a", appURL.path]
    try process.run()
    installLogger.notice(
        "install-mac launched agent path=\(appURL.path, privacy: .public)"
    )
}

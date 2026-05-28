import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

private let defaultInstallParentDirectory = "/Applications/CellTunnel"
private let installSubcommand = "install"
private let helpSubcommand = "--help"
private let helpShortSubcommand = "-h"
private let installArgumentPairStride = 2

@main
enum CellTunnelCtl {
    static func main() async {
        CellTunnelLog.bootstrap()
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == helpSubcommand || arguments.first == helpShortSubcommand {
            printUsage()
            return
        }

        if arguments.first == installSubcommand {
            await runInstall(arguments: Array(arguments.dropFirst()))
            return
        }

        let client = AgentClient()
        do {
            let action = try TunnelControlCLIAction.parse(arguments: arguments)
            let executor = TunnelControlCLIExecutor(client: client)
            let output = try await executor.run(action: action)
            if !output.isEmpty {
                print(output)
            }
            await client.shutdown()
        } catch {
            await client.shutdown()
            emit(error: error)
            exit(1)
        }
    }
}

private func printUsage() {
    let usage = """
        usage: celltunnelctl <command> [options]

        commands:
          status                       Print current tunnel daemon status.
          check                        Print environment check report.
          start-discovery              Start relay discovery on the agent.
          stop-discovery               Stop relay discovery on the agent.
          discover                     Start discovery and poll until a service is ready.
          probe                        Run status + start-discovery + list-relay-services in order.
          select <serviceID>           Select a discovered relay service.
          start --config <path>        Start the tunnel using the given WireGuard config.
                                       Optional: --relay <host:port>.
          stop                         Stop the tunnel.
          install [--app <path>] [--destination <dir>]
                                       Copy the built CellTunnelAgent.app into <dir> (defaults
                                       to \(defaultInstallParentDirectory)) and trigger the
                                       first-run VPN configuration sheet via the agent.
                                       When --app is omitted, the CLI looks for CellTunnelAgent.app
                                       next to the celltunnelctl binary.
          --help, -h                   Print this help text.
        """
    print(usage)
}

private func emit(error: Error) {
    if let daemonError = error as? TunnelDaemonError {
        FileHandle.standardError.write(Data("\(daemonError.renderedOutput)\n".utf8))
        return
    }
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
}

private func runInstall(arguments: [String]) async {
    do {
        let options = try parseInstallOptions(arguments: arguments)
        let installedAppURL = try installAgentBundle(options: options)
        try await primeVPNConfiguration(installedAppURL: installedAppURL)
        print("install complete bundle=\(installedAppURL.path)")
        print("approve the VPN configuration sheet in System Settings to finish setup")
    } catch {
        emit(error: error)
        exit(1)
    }
}

private struct InstallOptions {
    let sourceAppURL: URL?
    let destinationDirectoryURL: URL
}

private struct InstallCopyFailure {
    let destination: String
    let underlying: Error
}

private enum InstallError: LocalizedError {
    case copyFailed(InstallCopyFailure)
    case missingSource(String)
    case primeFailed(String)
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .copyFailed(let failure):
            return
                "install: copy to \(failure.destination) failed: \(failure.underlying.localizedDescription)"
        case .missingSource(let path):
            return "install: source bundle not found at \(path)"
        case .primeFailed(let message):
            return "install: VPN configuration prime failed: \(message)"
        case .usage(let message):
            return "install: \(message)"
        }
    }
}

private func parseInstallOptions(arguments: [String]) throws -> InstallOptions {
    var sourcePath: String?
    var destinationPath = defaultInstallParentDirectory

    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        let valueIndex = arguments.index(after: index)
        switch argument {
        case "--app":
            guard valueIndex < arguments.endIndex else {
                throw InstallError.usage("missing value for --app")
            }
            sourcePath = arguments[valueIndex]
            index = arguments.index(index, offsetBy: installArgumentPairStride)
        case "--destination":
            guard valueIndex < arguments.endIndex else {
                throw InstallError.usage("missing value for --destination")
            }
            destinationPath = arguments[valueIndex]
            index = arguments.index(index, offsetBy: installArgumentPairStride)
        default:
            throw InstallError.usage("unknown install option: \(argument)")
        }
    }

    let resolvedSource: URL?
    if let sourcePath {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw InstallError.usage("--app must not be empty")
        }
        resolvedSource = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    } else {
        resolvedSource = nil
    }

    let resolvedDestination = URL(
        fileURLWithPath: (destinationPath as NSString).expandingTildeInPath,
        isDirectory: true
    )
    return InstallOptions(
        sourceAppURL: resolvedSource,
        destinationDirectoryURL: resolvedDestination
    )
}

private func installAgentBundle(options: InstallOptions) throws -> URL {
    let source = try resolveInstallSourceURL(explicit: options.sourceAppURL)
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: options.destinationDirectoryURL,
        withIntermediateDirectories: true
    )
    let destinationApp = options.destinationDirectoryURL
        .appendingPathComponent(agentAppBundleName)
    if fileManager.fileExists(atPath: destinationApp.path) {
        do {
            try fileManager.removeItem(at: destinationApp)
        } catch {
            throw InstallError.copyFailed(
                InstallCopyFailure(destination: destinationApp.path, underlying: error)
            )
        }
    }
    do {
        try fileManager.copyItem(at: source, to: destinationApp)
    } catch {
        throw InstallError.copyFailed(
            InstallCopyFailure(destination: destinationApp.path, underlying: error)
        )
    }
    logger.notice(
        """
        celltunnelctl installed agent bundle source=\(source.path, privacy: .public) \
        destination=\(destinationApp.path, privacy: .public)
        """
    )
    return destinationApp
}

private func resolveInstallSourceURL(explicit: URL?) throws -> URL {
    let fileManager = FileManager.default
    if let explicit {
        if fileManager.fileExists(atPath: explicit.path) {
            return explicit
        }
        throw InstallError.missingSource(explicit.path)
    }
    let cliDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        .deletingLastPathComponent()
    let candidate = cliDirectory.appendingPathComponent(agentAppBundleName)
    if fileManager.fileExists(atPath: candidate.path) {
        return candidate
    }
    throw InstallError.missingSource(candidate.path)
}

private func primeVPNConfiguration(installedAppURL: URL) async throws {
    let executableURL =
        installedAppURL
        .appendingPathComponent("Contents/MacOS/\(agentBinaryName)")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw InstallError.primeFailed(
            "executable not found in installed bundle at \(executableURL.path)"
        )
    }
    let environment = [agentBinaryEnvironmentVariable: executableURL.path]
    let client = AgentClient(environment: environment)
    do {
        let report = try await client.check()
        await client.shutdown()
        if !report.renderedOutput.isEmpty {
            print(report.renderedOutput)
        }
    } catch {
        await client.shutdown()
        throw InstallError.primeFailed(error.localizedDescription)
    }
}

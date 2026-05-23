import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

enum TunnelDaemonCommand: Sendable {
    case startDryRun
    case stopDryRun
    case status

    var arguments: [String] {
        switch self {
        case .startDryRun:
            return ["start", "--dry-run"]
        case .stopDryRun:
            return ["stop", "--dry-run"]
        case .status:
            return ["status"]
        }
    }

    var logName: String {
        switch self {
        case .startDryRun:
            return "start-dry-run"
        case .stopDryRun:
            return "stop-dry-run"
        case .status:
            return "status"
        }
    }
}

struct TunnelDaemonCommandOutput: Sendable {
    let text: String
}

struct TunnelDaemonClient {
    func run(command: TunnelDaemonCommand) throws -> TunnelDaemonCommandOutput {
        let root = projectRoot()
        let daemonURL = try daemonExecutable(root: root)

        let process = Process()
        process.executableURL = daemonURL
        process.arguments = command.arguments
        process.currentDirectoryURL = root

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        logger.notice(
            """
            running celltunneld command=\(command.logName, privacy: .public) \
            executable=\(daemonURL.path, privacy: .public)
            """
        )
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            logger.error(
                """
                celltunneld command failed command=\(command.logName, privacy: .public) \
                status=\(process.terminationStatus, privacy: .public)
                """
            )
            throw TunnelDaemonError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if !errorOutput.isEmpty {
            logger.notice(
                """
                celltunneld emitted diagnostic output command=\(command.logName, privacy: .public) \
                bytes=\(errorOutput.utf8.count, privacy: .public)
                """
            )
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.notice("celltunneld command completed command=\(command.logName, privacy: .public)")
        return TunnelDaemonCommandOutput(text: trimmedOutput)
    }

    private func projectRoot() -> URL {
        let environmentRoot = ProcessInfo.processInfo.environment["CELL_TUNNEL_ROOT"]
        if let environmentRoot, !environmentRoot.isEmpty {
            return URL(fileURLWithPath: environmentRoot)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func daemonExecutable(root: URL) throws -> URL {
        let daemonURL = root.appendingPathComponent("Products/celltunneld")
        guard FileManager.default.fileExists(atPath: daemonURL.path) else {
            logger.error("celltunneld product missing path=\(daemonURL.path, privacy: .public)")
            throw TunnelDaemonError.missingDaemon(daemonURL.path)
        }

        logger.notice("celltunneld product resolved path=\(daemonURL.path, privacy: .public)")
        return daemonURL
    }
}

enum TunnelDaemonError: LocalizedError {
    case commandFailed(String)
    case missingDaemon(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message.isEmpty ? "celltunneld failed" : message
        case .missingDaemon(let path):
            return "celltunneld is missing at \(path)"
        }
    }
}

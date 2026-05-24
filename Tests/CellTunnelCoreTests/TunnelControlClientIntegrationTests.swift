import CellTunnelCore
import Foundation
import XCTest

final class TunnelControlClientIntegrationTests: XCTestCase {
    func testStatusAgainstGoUnixSocketServer() async throws {
        let harness = try GoDaemonHarness()
        try harness.start()
        defer {
            harness.stop()
        }

        let client = TunnelControlClient(socketPath: harness.socketPath)

        let status = try await client.status()

        XCTAssertFalse(status.running)
        XCTAssertEqual(status.routeState, .notInstalled)
        await client.shutdown()
    }

    func testDiscoveryAgainstGoUnixSocketServer() async throws {
        let harness = try GoDaemonHarness()
        try harness.start()
        defer {
            harness.stop()
        }

        let client = TunnelControlClient(socketPath: harness.socketPath)

        let discoveryStart = try await client.startRelayDiscovery()
        let discoveryList = try await client.listRelayServices()

        XCTAssertNotEqual(discoveryStart.phase, .failed)
        XCTAssertNotEqual(discoveryList.phase, .failed)
        await client.shutdown()
    }
}

private final class GoDaemonHarness {
    let socketPath: String

    private let directoryURL: URL
    private let process: Process
    private let outputPipe: Pipe

    init() throws {
        let directoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ct-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        self.directoryURL = directoryURL
        self.socketPath = directoryURL.appendingPathComponent("control.sock").path
        self.process = Process()
        self.outputPipe = Pipe()
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["go", "run", "./cmd/celltunneld", "serve"]
        process.currentDirectoryURL = repoRoot().appendingPathComponent("Daemon")
        var environment = ProcessInfo.processInfo.environment
        environment["CELL_TUNNEL_CONTROL_SOCKET"] = socketPath
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        try waitForSocket()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func waitForSocket() throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return
            }
            if !process.isRunning {
                let description = "Go daemon exited before socket was created: \(capturedOutput())"
                throw NSError(
                    domain: "GoDaemonHarness",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw NSError(
            domain: "GoDaemonHarness",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for Go daemon socket: \(capturedOutput())"
            ]
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func capturedOutput() -> String {
        let data = outputPipe.fileHandleForReading.availableData
        return String(data: data, encoding: .utf8) ?? ""
    }
}

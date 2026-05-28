import CellTunnelCore
import Foundation
import XCTest

final class TunnelControlSocketPathTests: XCTestCase {
    func testResolvedPathFallsBackToDefaultWhenEnvIsAbsent() {
        let resolved = resolvedTunnelControlSocketPath(environment: [:])

        XCTAssertEqual(resolved, defaultTunnelControlSocketPath)
    }

    func testResolvedPathUsesEnvOverrideWhenSet() {
        let resolved = resolvedTunnelControlSocketPath(
            environment: [tunnelControlSocketEnvironmentVariable: "/tmp/dev.sock"]
        )

        XCTAssertEqual(resolved, "/tmp/dev.sock")
    }

    func testResolvedPathIgnoresEmptyOrWhitespaceEnvOverride() {
        let blank = resolvedTunnelControlSocketPath(
            environment: [tunnelControlSocketEnvironmentVariable: ""]
        )
        let whitespace = resolvedTunnelControlSocketPath(
            environment: [tunnelControlSocketEnvironmentVariable: "   "]
        )

        XCTAssertEqual(blank, defaultTunnelControlSocketPath)
        XCTAssertEqual(whitespace, defaultTunnelControlSocketPath)
    }

    func testSwiftDefaultPathMatchesGoDaemonLiteral() throws {
        let source = try readGoDaemonMainSource()
        let goLiteral = try extractGoStringConstant(
            named: "defaultControlSocketPath", from: source)

        XCTAssertEqual(
            goLiteral,
            defaultTunnelControlSocketPath,
            "Swift defaultTunnelControlSocketPath drifted from Go defaultControlSocketPath"
        )
    }

    func testSwiftEnvVarNameMatchesGoDaemonLiteral() throws {
        let source = try readGoDaemonMainSource()
        let goLiteral = try extractGoStringConstant(
            named: "controlSocketEnvironment", from: source)

        XCTAssertEqual(
            goLiteral,
            tunnelControlSocketEnvironmentVariable,
            "Swift tunnelControlSocketEnvironmentVariable drifted from Go controlSocketEnvironment"
        )
    }

    private func readGoDaemonMainSource() throws -> String {
        let mainURL = repositoryRoot()
            .appendingPathComponent("Daemon", isDirectory: true)
            .appendingPathComponent("cmd", isDirectory: true)
            .appendingPathComponent("celltunneld", isDirectory: true)
            .appendingPathComponent("main.go", isDirectory: false)
        return try String(contentsOf: mainURL, encoding: .utf8)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func extractGoStringConstant(named name: String, from source: String) throws -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?m)^\\s*\(escapedName)\\s*=\\s*\"([^\"]+)\""
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard
            let match = regex.firstMatch(in: source, options: [], range: range),
            let valueRange = Range(match.range(at: 1), in: source)
        else {
            throw GoConstantExtractionError.notFound(name: name)
        }
        return String(source[valueRange])
    }

    private enum GoConstantExtractionError: Error, CustomStringConvertible {
        case notFound(name: String)

        var description: String {
            switch self {
            case .notFound(let name):
                return "Go constant \(name) not found in Daemon/cmd/celltunneld/main.go"
            }
        }
    }
}

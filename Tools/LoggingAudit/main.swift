import Foundation
import SwiftParser
import SwiftSyntax

enum AuditRule: String {
    case bannedOutput
    case catchLogging
    case directLoggerConstruction
    case inlineLintDisable
    case loggerDeclaration
    case missingBoundaryLog
    case missingPrivacy
    case warningLevel
}

struct AuditAllowlistEntry {
    let pathSuffix: String
    let rule: AuditRule
    let reason: String

    func allows(path: String, rule: AuditRule) -> Bool {
        path.hasSuffix(pathSuffix) && self.rule == rule && !reason.isEmpty
    }
}

struct Violation: CustomStringConvertible {
    let path: String
    let line: Int
    let rule: AuditRule
    let message: String

    var description: String {
        "\(path):\(line): \(rule.rawValue): \(message)"
    }
}

let runtimeRoots = [
    "Apps",
    "Sources/CellTunnelCore",
    "Sources/CellTunnelLog",
]

let allowlist = [
    AuditAllowlistEntry(
        pathSuffix: "Sources/CellTunnelLog/CellTunnelLog.swift",
        rule: .directLoggerConstruction,
        reason: "CellTunnelLog is the single subsystem construction boundary."
    ),
    AuditAllowlistEntry(
        pathSuffix: "Sources/CellTunnelLog/CellTunnelLog.swift",
        rule: .loggerDeclaration,
        reason: "CellTunnelLog exports categories instead of declaring a private category."
    ),
    AuditAllowlistEntry(
        pathSuffix: "Sources/CellTunnelCore/TunnelControlModels.swift",
        rule: .loggerDeclaration,
        reason: "TunnelControlModels contains Codable socket payloads and no runtime side effects."
    ),
]

let boundaryNeedles = [
    "NWPathMonitor",
    "NWListener",
    "NWConnection",
    "receive(",
    "send(",
    "cancel()",
    "stateUpdateHandler",
    "pathUpdateHandler",
    "Process()",
    "process.run",
    "waitUntilExit",
    "runDaemon",
    "start(",
    "stop(",
    "refreshStatus",
    "isRunning =",
    "isAdvertising =",
    "tunnelState =",
    "routeState =",
    "daemonOutput =",
]

let logNeedles = [
    ".debug(",
    ".error(",
    ".info(",
    ".notice(",
]

func allows(path: String, rule: AuditRule) -> Bool {
    allowlist.contains { entry in
        entry.allows(path: path, rule: rule)
    }
}

func lineNumber(for offset: AbsolutePosition, converter: SourceLocationConverter) -> Int {
    converter.location(for: offset).line
}

func swiftFiles(root: String) -> [String] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(atPath: root) else {
        return []
    }

    var files: [String] = []
    for entry in enumerator {
        guard let relativePath = entry as? String else {
            continue
        }
        guard relativePath.hasSuffix(".swift") else {
            continue
        }
        files.append("\(root)/\(relativePath)")
    }
    return files.sorted()
}

func containsLogCall(_ source: String) -> Bool {
    logNeedles.contains { needle in
        source.contains(needle)
    }
}

func containsBoundary(_ source: String) -> Bool {
    boundaryNeedles.contains { needle in
        source.contains(needle)
    }
}

func countPrivateLoggerDeclarations(lines: [String]) -> Int {
    lines.filter { line in
        line.contains("private let logger = CellTunnelLog.logger(category:")
    }.count
}

func hasBannedOutput(line: String) -> Bool {
    let bannedNeedles = [
        "print(",
        "debugPrint(",
        "dump(",
        "NSLog(",
        "os_log(",
    ]
    return bannedNeedles.contains { needle in
        line.contains(needle)
    }
}

func isCommentOnly(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
}

func auditText(path: String, lines: [String], violations: inout [Violation]) {
    let loggerDeclarationCount = countPrivateLoggerDeclarations(lines: lines)
    let joinedSource = lines.joined(separator: "\n")
    let requiresLoggerDeclaration = containsBoundary(joinedSource) && loggerDeclarationCount == 0
    if requiresLoggerDeclaration, !allows(path: path, rule: .loggerDeclaration) {
        violations.append(
            Violation(
                path: path,
                line: 1,
                rule: .loggerDeclaration,
                message: "runtime boundary files must declare one private CellTunnelLog category"
            )
        )
    }
    if loggerDeclarationCount > 1 {
        violations.append(
            Violation(
                path: path,
                line: 1,
                rule: .loggerDeclaration,
                message: "runtime files should use one private logger category"
            )
        )
    }

    for (index, line) in lines.enumerated() where !isCommentOnly(line) {
        let lineNumber = index + 1
        if line.contains("swiftlint:disable") {
            violations.append(
                Violation(
                    path: path,
                    line: lineNumber,
                    rule: .inlineLintDisable,
                    message: "runtime Swift code must not disable SwiftLint inline"
                )
            )
        }
        if hasBannedOutput(line: line) {
            violations.append(
                Violation(
                    path: path,
                    line: lineNumber,
                    rule: .bannedOutput,
                    message: "use CellTunnelLog instead of direct runtime output"
                )
            )
        }
        if line.contains(".warning(") {
            violations.append(
                Violation(
                    path: path,
                    line: lineNumber,
                    rule: .warningLevel,
                    message: "use notice for recoverable events or error for failures"
                )
            )
        }
    }
}

final class AuditVisitor: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private(set) var violations: [Violation] = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calledExpression = node.calledExpression.description.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let source = node.description
        let line = lineNumber(for: node.positionAfterSkippingLeadingTrivia, converter: converter)

        if calledExpression == "Logger", !allows(path: path, rule: .directLoggerConstruction) {
            violations.append(
                Violation(
                    path: path,
                    line: line,
                    rule: .directLoggerConstruction,
                    message: "construct runtime loggers through CellTunnelLog"
                )
            )
        }

        if isLogCall(calledExpression), source.contains(#"\("#), !source.contains("privacy:") {
            violations.append(
                Violation(
                    path: path,
                    line: line,
                    rule: .missingPrivacy,
                    message: "log interpolation must declare an explicit privacy"
                )
            )
        }

        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else {
            return .visitChildren
        }

        let bodySource = body.description
        if containsBoundary(bodySource), !containsLogCall(bodySource) {
            let line = lineNumber(
                for: node.positionAfterSkippingLeadingTrivia, converter: converter)
            violations.append(
                Violation(
                    path: path,
                    line: line,
                    rule: .missingBoundaryLog,
                    message:
                        "I/O, process, network, lifecycle, command, state, and recovery boundaries must log context"
                )
            )
        }

        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        let source = node.description
        if !containsLogCall(source) {
            let line = lineNumber(
                for: node.positionAfterSkippingLeadingTrivia, converter: converter)
            violations.append(
                Violation(
                    path: path,
                    line: line,
                    rule: .catchLogging,
                    message: "catch blocks must log failure context and recovery decision"
                )
            )
        }
        return .visitChildren
    }

    private func isLogCall(_ calledExpression: String) -> Bool {
        calledExpression.hasSuffix(".debug")
            || calledExpression.hasSuffix(".error")
            || calledExpression.hasSuffix(".info")
            || calledExpression.hasSuffix(".notice")
            || calledExpression.hasSuffix(".warning")
    }
}

func audit(path: String) -> [Violation] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        return [
            Violation(
                path: path,
                line: 1,
                rule: .missingBoundaryLog,
                message: "could not read Swift source"
            )
        ]
    }

    let sourceFile = Parser.parse(source: contents)
    let converter = SourceLocationConverter(fileName: path, tree: sourceFile)
    var violations: [Violation] = []
    auditText(
        path: path,
        lines: contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
        violations: &violations
    )

    let visitor = AuditVisitor(path: path, converter: converter)
    visitor.walk(sourceFile)
    violations.append(contentsOf: visitor.violations)
    return violations.filter { violation in
        !allows(path: violation.path, rule: violation.rule)
    }
}

let violations = runtimeRoots.flatMap(swiftFiles(root:)).flatMap(audit(path:))

if violations.isEmpty {
    FileHandle.standardOutput.write(Data("log-audit: ok\n".utf8))
} else {
    for violation in violations {
        FileHandle.standardError.write(Data("\(violation)\n".utf8))
    }
    FileHandle.standardError.write(
        Data("log-audit failed: \(violations.count) violation(s)\n".utf8))
    exit(1)
}

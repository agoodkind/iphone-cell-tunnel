import Foundation

func printHelp() {
    print(
        """
        usage: swift Tools/cell-tunnel-dev.swift <command>

        commands:
          help        Show this help text.
          generate    Install Tuist dependencies and generate CellTunnel.xcworkspace.
          build       Run lint, audit, then build the named target.
                      Targets: daemon|mac|iphone-simulator|iphone-device|all
                      Bare `build` with no target prints this and exits non-zero.
          activate    Install, register, and launch the requested target from built products.
                      Pass --port <listener-port> to override the iPhone relay listener port at launch.
          install-mac Copy the built CellTunnelAgent.app into /Applications/CellTunnel and launch it
                      so its first run registers the LaunchAgent.
                      Options: --config Debug|Release, --app <path>, --destination <dir>.
          test        Run SwiftPM tests.
          lint        Run Swift lint gates.
          format      Format Swift sources.
          log-audit   Run the SwiftSyntax logging audit.
          audit       Run lint and log-audit.
          analyze     Run Xcode analyze, SwiftLint analyze, and Periphery.
          build-phone-device
                      Build CellTunnelPhone for a connected physical iPhone.
          install-phone-device
                      Build and install CellTunnelPhone on a connected physical iPhone.
          launch-phone-device
                      Launch CellTunnelPhone on a connected physical iPhone.
          iphone-logs Stream iPhone or simulator logs. See `iphone-logs --help`.
          clean       Remove build and product outputs.
        """
    )
}

func parseConfiguration(command: String) throws -> String {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard arguments.count <= 1 else {
        throw ToolError.usage("usage: \(command) [Debug|Release]")
    }
    return arguments.first ?? "Debug"
}

func parseBuildTarget() throws -> (BuildTarget, String) {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    let usage = "usage: build <\(buildTargetUsage)> [Debug|Release]"
    guard let raw = arguments.first else {
        throw ToolError.usage(usage)
    }
    guard let target = BuildTarget(rawValue: raw) else {
        throw ToolError.usage("unknown build target: \(raw). \(usage)")
    }
    guard arguments.count <= 2 else {
        throw ToolError.usage(usage)
    }
    let configuration = arguments.count == 2 ? arguments[1] : "Debug"
    return (target, configuration)
}

func parseActivation(command: String) throws -> ActivationOptions {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    let usage =
        "usage: \(command) <\(activationTargetUsage)> [Debug|Release] [--port <listener-port>]"
    guard let rawTarget = arguments.first else {
        throw ToolError.usage(usage)
    }
    guard let target = ActivationTarget(rawValue: rawTarget) else {
        throw ToolError.usage(
            "unknown target: \(rawTarget); expected one of \(activationTargetUsage)")
    }

    var configuration = "Debug"
    var listenerPort: UInt16?
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--port" {
            guard index + 1 < arguments.count else {
                throw ToolError.usage("missing value for --port. \(usage)")
            }
            guard let port = UInt16(arguments[index + 1]), port >= 1 else {
                throw ToolError.usage(
                    "invalid --port value: \(arguments[index + 1]). \(usage)")
            }
            listenerPort = port
            index += 2
            continue
        }
        if configuration == "Debug", argument == "Debug" || argument == "Release" {
            configuration = argument
            index += 1
            continue
        }
        throw ToolError.usage("unknown activation argument: \(argument). \(usage)")
    }

    return ActivationOptions(
        target: target, configuration: configuration, listenerPort: listenerPort)
}

struct ActivationOptions {
    let target: ActivationTarget
    let configuration: String
    let listenerPort: UInt16?
}

func runCommand(_ command: String) throws {
    if try runCoreCommand(command) {
        return
    }
    if try runAuditCommand(command) {
        return
    }
    if try runDeviceCommand(command) {
        return
    }
    if try runLogCommand(command) {
        return
    }
    throw ToolError.usage("unknown command: \(command)")
}

func runLogCommand(_ command: String) throws -> Bool {
    switch command {
    case "iphone-logs":
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        try runIPhoneLogs(arguments)
        return true
    default:
        return false
    }
}

func runCoreCommand(_ command: String) throws -> Bool {
    switch command {
    case "help":
        printHelp()
        return true
    case "generate":
        try generateProject()
        return true
    case "build":
        let (target, configuration) = try parseBuildTarget()
        try buildProject(target: target, configuration: configuration)
        return true
    case "activate":
        let options = try parseActivation(command: command)
        try activateTarget(
            options.target,
            configuration: options.configuration,
            listenerPort: options.listenerPort
        )
        return true
    case "install-mac":
        let options = try parseInstallMacOptions()
        try runInstallMac(options: options)
        return true
    case "test":
        try testProject()
        return true
    case "lint":
        try lintProject()
        return true
    case "format":
        try formatProject()
        return true
    case "clean":
        try cleanProject()
        return true
    default:
        return false
    }
}

func runAuditCommand(_ command: String) throws -> Bool {
    switch command {
    case "log-audit":
        try auditLogging()
        return true
    case "audit":
        try lintProject()
        try auditLogging()
        return true
    case "analyze":
        try analyzeProject()
        return true
    default:
        return false
    }
}

func runDeviceCommand(_ command: String) throws -> Bool {
    switch command {
    case "build-phone-device":
        let configuration = try parseConfiguration(command: command)
        try buildPhoneDevice(configuration: configuration)
        return true
    case "install-phone-device":
        let configuration = try parseConfiguration(command: command)
        try installPhoneDevice(configuration: configuration)
        return true
    case "launch-phone-device":
        try launchPhoneDevice()
        return true
    default:
        return false
    }
}

func main() throws {
    let command = CommandLine.arguments.dropFirst().first ?? "help"
    try runCommand(command)
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

import Foundation

func printHelp() {
    print(
        """
        usage: swift Tools/cell-tunnel-dev.swift <command>

        commands:
          help        Show this help text.
          generate    Install Tuist dependencies and generate CellTunnel.xcworkspace.
          build       Generate and build every target, tool, and daemon product.
          activate    Install, register, and launch the requested target from built products.
          test        Run SwiftPM tests and Go daemon tests.
          lint        Run Swift and Go lint gates.
          format      Format Swift and Go sources.
          log-audit   Run the SwiftSyntax logging audit.
          go-audit    Run Go vet, vuln, deadcode, and staticcheck-extra gates.
          audit       Run lint, log-audit, and go-audit.
          analyze     Run Xcode analyze, SwiftLint analyze, Periphery, and Go analyzers.
          sign        Sign the Mac app bundle and daemon products.
          signing-check
                      Verify signing configuration and signed Mac products.
          notary-setup
                      Store notarytool credentials in the configured keychain profile.
          notarize-check
                      Verify notarytool credential availability without submitting.
          notarize   Build, submit, staple, and assess the signed macOS app.
          build-phone-device
                      Build CellTunnelPhone for a connected physical iPhone.
          install-phone-device
                      Build and install CellTunnelPhone on a connected physical iPhone.
          launch-phone-device
                      Launch CellTunnelPhone on a connected physical iPhone.
          clean       Remove build and product outputs.
          run         Build and launch the macOS app.
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

func parseActivation(command: String) throws -> (ActivationTarget, String) {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard let rawTarget = arguments.first else {
        throw ToolError.usage("usage: \(command) <\(activationTargetUsage)> [Debug|Release]")
    }
    guard arguments.count <= 2 else {
        throw ToolError.usage("usage: \(command) <\(activationTargetUsage)> [Debug|Release]")
    }
    guard let target = ActivationTarget(rawValue: rawTarget) else {
        throw ToolError.usage(
            "unknown target: \(rawTarget); expected one of \(activationTargetUsage)")
    }
    let configuration = arguments.count == 2 ? arguments[1] : "Debug"
    return (target, configuration)
}

func main() throws {
    let command = CommandLine.arguments.dropFirst().first ?? "help"
    switch command {
    case "help":
        printHelp()
    case "generate":
        try generateProject()
    case "build":
        let configuration = try parseConfiguration(command: command)
        try buildProject(configuration: configuration)
    case "activate":
        let (target, configuration) = try parseActivation(command: command)
        try activateTarget(target, configuration: configuration)
    case "test":
        try testProject()
    case "lint":
        try lintProject()
    case "format":
        try formatProject()
    case "log-audit":
        try auditLogging()
    case "go-audit":
        try auditGoProject()
    case "audit":
        try lintProject()
        try auditLogging()
        try auditGoProject()
    case "analyze":
        try analyzeProject()
    case "sign":
        let configuration = try parseConfiguration(command: command)
        let config = try signingConfig()
        try packageMacBundle(configuration: configuration, signing: config)
        try signMacProducts(configuration: configuration, signing: config)
    case "signing-check":
        try signingCheck()
    case "notary-setup":
        try notarySetup()
    case "notarize-check":
        try notarizeCheck()
    case "notarize":
        let configuration = try parseConfiguration(command: command)
        try notarizeMacApp(configuration: configuration)
    case "build-phone-device":
        let configuration = try parseConfiguration(command: command)
        try buildPhoneDevice(configuration: configuration)
    case "install-phone-device":
        let configuration = try parseConfiguration(command: command)
        try installPhoneDevice(configuration: configuration)
    case "launch-phone-device":
        try launchPhoneDevice()
    case "clean":
        try cleanProject()
    case "run":
        try runMacApp()
    default:
        throw ToolError.usage("unknown command: \(command)")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

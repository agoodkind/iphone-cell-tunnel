import Foundation

enum BuildTarget: String, CaseIterable {
    case daemon
    case mac
    case iphoneSimulator = "iphone-simulator"
    case iphoneDevice = "iphone-device"
    case all
}

let buildTargetUsage = BuildTarget.allCases.map(\.rawValue).joined(separator: "|")

func buildProject(target: BuildTarget, configuration: String) throws {
    try runBuildPrologue()
    try buildCLI()

    switch target {
    case .daemon:
        try buildDaemon(configuration: configuration)
    case .mac:
        let signing = try requireSigningConfig()
        try buildDaemon(configuration: configuration)
        try buildMacBundle(configuration: configuration, signing: signing)
    case .iphoneSimulator:
        try buildIPhoneSimulator(configuration: configuration)
    case .iphoneDevice:
        let signing = try requireSigningConfig()
        try buildPhoneDevice(
            configuration: configuration,
            signing: signing,
            shouldGenerateProject: false
        )
    case .all:
        let signing = try requireSigningConfig()
        try buildDaemon(configuration: configuration)
        try buildMacBundle(configuration: configuration, signing: signing)
        try buildIPhoneSimulator(configuration: configuration)
        try buildPhoneDevice(
            configuration: configuration,
            signing: signing,
            shouldGenerateProject: false
        )
    }

    try printBuildArtifactFingerprints(target: target, configuration: configuration)
}

private func requireSigningConfig() throws -> SigningConfig {
    let resolved = try signingConfig()
    try requireSigningIdentity(resolved)
    return resolved
}

private func runBuildPrologue() throws {
    try generateProject()
    try lintSwiftProject()
    try auditLogging()
}

private func buildCLI() throws {
    try buildSwiftProduct("celltunnelctl")
    try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
    try installSwiftExecutable(productName: "celltunnelctl", outputName: "celltunnelctl")
}

private func buildDaemon(configuration: String) throws {
    try buildWireGuardGoBridge()
    try buildScheme(
        scheme: "celltunneld",
        configuration: configuration,
        destination: "platform=macOS",
        platformName: macOSPlatformName
    )
    try buildScheme(
        scheme: "celltunneldhelperd",
        configuration: configuration,
        destination: "platform=macOS",
        platformName: macOSPlatformName
    )
    try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
    try installBuiltDaemon(configuration: configuration)
    try installBuiltHelper(configuration: configuration)
}

private func buildMacBundle(configuration: String, signing: SigningConfig) throws {
    try buildScheme(
        scheme: "CellTunnelMac",
        configuration: configuration,
        destination: "platform=macOS",
        platformName: macOSPlatformName
    )
    try packageMacBundle(configuration: configuration, signing: signing)
    try signMacProducts(configuration: configuration, signing: signing)
}

private func buildIPhoneSimulator(configuration: String) throws {
    try buildScheme(
        scheme: "CellTunnelPhone",
        configuration: configuration,
        destination: ProcessInfo.processInfo.environment["IOS_SIMULATOR_DESTINATION"]
            ?? "generic/platform=iOS Simulator",
        platformName: iOSSimulatorPlatformName
    )
}

private func printBuildArtifactFingerprints(target: BuildTarget, configuration: String) throws {
    let ctlPath = productsDirectory.appendingPathComponent("celltunnelctl").path
    let daemonPath = productsDirectory.appendingPathComponent("celltunneld").path
    let helperPath = productsDirectory.appendingPathComponent(helperDaemonProductName).path
    print("")
    print("build artifacts (target=\(target.rawValue) configuration=\(configuration)):")
    try printArtifactFingerprint(label: "celltunnelctl     ", path: ctlPath)
    if target == .daemon || target == .mac || target == .all {
        try printArtifactFingerprint(label: "celltunneld       ", path: daemonPath)
        try printArtifactFingerprint(label: "celltunneldhelperd", path: helperPath)
    }
}

private func printArtifactFingerprint(label: String, path: String) throws {
    if !fileManager.fileExists(atPath: path) {
        print("  \(label): missing at \(path)")
        return
    }
    let result = try capture("shasum", ["-a", "256", path], echoOutput: false)
    if result.status == 0 {
        let line = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        print("  \(label): \(line)")
    } else {
        print("  \(label): shasum failed status=\(result.status)")
    }
}

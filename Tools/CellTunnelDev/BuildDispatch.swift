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
    try buildDaemonAndCLI()

    switch target {
    case .daemon:
        break
    case .mac:
        let signing = try requireSigningConfig()
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
    try lintGoProject()
    try auditLogging()
    try auditGoProject()
}

private func buildDaemonAndCLI() throws {
    try buildSwiftProduct("celltunnelctl")
    try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
    try installSwiftExecutable(productName: "celltunnelctl", outputName: "celltunnelctl")
    try runGoMake("build")
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
    let daemonPath = productsDirectory.appendingPathComponent("celltunneld").path
    let ctlPath = productsDirectory.appendingPathComponent("celltunnelctl").path
    print("")
    print("build artifacts (target=\(target.rawValue) configuration=\(configuration)):")
    try printArtifactFingerprint(label: "celltunneld   ", path: daemonPath)
    try printArtifactFingerprint(label: "celltunnelctl ", path: ctlPath)

    if target == .mac || target == .all {
        let bundledDaemon = installedMacAppPath.appendingPathComponent(helperExecutableRelativePath)
            .path
        let bundledLocal = xcodeConfigurationBuildDirectory(
            configuration: configuration, platformName: macOSPlatformName
        )
        .appendingPathComponent("CellTunnelMac.app")
        .appendingPathComponent(helperExecutableRelativePath)
        .path
        try printArtifactFingerprint(label: "bundle daemon ", path: bundledLocal)
        try printArtifactFingerprint(label: "installed dmn ", path: bundledDaemon)
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

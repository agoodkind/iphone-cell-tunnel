import Foundation

struct SigningConfig {
    let codeSignIdentity: String
    let developmentTeam: String
    let bundleIdentifierPrefix: String
    let notaryProfile: String
    let developerCertificatesDirectory: URL

    var macAppEntitlements: URL {
        repoRoot.appendingPathComponent("Apps/macOS/Entitlements/CellTunnelMac.entitlements")
    }

    var daemonEntitlements: URL {
        repoRoot.appendingPathComponent("Apps/macOS/Entitlements/celltunneld.entitlements")
    }

    var launchDaemonPlist: URL {
        repoRoot.appendingPathComponent(
            "Apps/macOS/LaunchDaemons/\(daemonLaunchDaemonPlistName)")
    }

    var notaryKeyPath: URL {
        developerCertificatesDirectory.appendingPathComponent("AuthKey_JHC8GR65Q3.p8")
    }
}

struct SigningIdentity {
    let hash: String
}

extension Dictionary where Key == String, Value == String {
    func required(_ key: String) throws -> String {
        guard let value = self[key], !value.isEmpty else {
            throw ToolError.failure("missing required signing value: \(key)")
        }
        return value
    }
}

func signingConfig() throws -> SigningConfig {
    let values = try signingValues()
    let certificatesDirectory = values["DEV_CERTS_DIR"] ?? "\(NSHomeDirectory())/Desktop/dev-certs"
    return SigningConfig(
        codeSignIdentity: values["CODE_SIGN_IDENTITY"] ?? defaultDeveloperIDIdentity,
        developmentTeam: values["DEVELOPMENT_TEAM"] ?? defaultDevelopmentTeam,
        bundleIdentifierPrefix: values["BUNDLE_ID_PREFIX"] ?? defaultBundleIdentifierPrefix,
        notaryProfile: values["NOTARY_PROFILE"] ?? defaultNotaryProfile,
        developerCertificatesDirectory: URL(fileURLWithPath: certificatesDirectory)
    )
}

func signingValues() throws -> [String: String] {
    var values =
        try fileManager.fileExists(atPath: signingConfigURL.path)
        ? parseKeyValueFile(signingConfigURL) : [:]
    for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CELL_TUNNEL_") {
        let signingKey = String(key.dropFirst("CELL_TUNNEL_".count))
        values[signingKey] = value
    }
    return values
}

func parseKeyValueFile(_ url: URL) throws -> [String: String] {
    let content = try String(contentsOf: url, encoding: .utf8)
    var values: [String: String] = [:]
    for rawLine in content.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }

        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue
        }

        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = strippedQuotes(String(parts[1]).trimmingCharacters(in: .whitespaces))
        values[key] = value
    }
    return values
}

func strippedQuotes(_ value: String) -> String {
    guard value.count >= 2 else {
        return value
    }

    if value.hasPrefix("\""), value.hasSuffix("\"") {
        return String(value.dropFirst().dropLast())
    }
    if value.hasPrefix("'"), value.hasSuffix("'") {
        return String(value.dropFirst().dropLast())
    }
    return value
}

func requireSigningIdentity(_ config: SigningConfig) throws {
    _ = try resolvedSigningIdentity(config)
}

func resolvedSigningIdentity(_ config: SigningConfig) throws -> SigningIdentity {
    let result = try capture(
        "security", ["find-identity", "-p", "codesigning", "-v"], echoOutput: false)
    guard result.status == 0 else {
        throw ToolError.failure("codesigning identity lookup failed")
    }

    if isCodeSignHash(config.codeSignIdentity), result.output.contains(config.codeSignIdentity) {
        return SigningIdentity(hash: config.codeSignIdentity)
    }

    let quotedIdentity = "\"\(config.codeSignIdentity)\""
    let identityLines = result.output.components(separatedBy: .newlines)
    for line in identityLines where line.contains(quotedIdentity) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            continue
        }
        return SigningIdentity(hash: String(parts[1]))
    }

    throw ToolError.failure("required signing identity not available: \(config.codeSignIdentity)")
}

func isCodeSignHash(_ value: String) -> Bool {
    guard value.count == 40 else {
        return false
    }
    return value.allSatisfy(\.isHexDigit)
}

func macAppPath(configuration: String) -> URL {
    productsDirectory.appendingPathComponent("\(configuration)/macosx/CellTunnelMac.app")
}

func packageMacBundle(configuration: String, signing: SigningConfig) throws {
    let appPath = macAppPath(configuration: configuration)
    guard fileManager.fileExists(atPath: appPath.path) else {
        throw ToolError.failure("built app not found: \(appPath.path)")
    }

    let daemonSource = productsDirectory.appendingPathComponent(daemonProductName)
    guard fileManager.fileExists(atPath: daemonSource.path) else {
        throw ToolError.failure("built daemon not found: \(daemonSource.path)")
    }

    guard fileManager.fileExists(atPath: signing.launchDaemonPlist.path) else {
        throw ToolError.failure(
            "launch daemon plist not found: \(signing.launchDaemonPlist.path)")
    }

    let libraryPath = appPath.appendingPathComponent("Contents/Library")
    if fileManager.fileExists(atPath: libraryPath.path) {
        try fileManager.removeItem(at: libraryPath)
    }
    let launchServices = libraryPath.appendingPathComponent("LaunchServices")
    let launchDaemons = libraryPath.appendingPathComponent("LaunchDaemons")
    try fileManager.createDirectory(at: launchServices, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: launchDaemons, withIntermediateDirectories: true)

    let daemonDestination = launchServices.appendingPathComponent(daemonProductName)
    let daemonPlistDestination = launchDaemons.appendingPathComponent(daemonLaunchDaemonPlistName)

    try copyReplacingItem(at: daemonSource, to: daemonDestination)
    try fileManager.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: daemonDestination.path)
    try copyReplacingItem(at: signing.launchDaemonPlist, to: daemonPlistDestination)
}

func signMacProducts(configuration: String, signing: SigningConfig) throws {
    try requireTool("codesign")
    let identity = try resolvedSigningIdentity(signing)
    let appPath = macAppPath(configuration: configuration)
    let daemonInProducts = productsDirectory.appendingPathComponent(daemonProductName)
    let daemonInBundle = appPath.appendingPathComponent(daemonExecutableRelativePath)

    try signPath(
        daemonInProducts,
        identity: identity.hash,
        identifier: "\(signing.bundleIdentifierPrefix).\(daemonProductName)",
        entitlements: signing.daemonEntitlements
    )
    try signNestedCode(in: appPath, signing: signing, identity: identity.hash)
    try signPath(
        daemonInBundle,
        identity: identity.hash,
        identifier: "\(signing.bundleIdentifierPrefix).\(daemonProductName)",
        entitlements: signing.daemonEntitlements
    )
    try signPath(
        appPath,
        identity: identity.hash,
        identifier: "\(signing.bundleIdentifierPrefix).CellTunnelMac",
        entitlements: signing.macAppEntitlements
    )
    try run("codesign", ["--verify", "--strict", "--deep", "--verbose=2", appPath.path])
}

func signNestedCode(in appPath: URL, signing: SigningConfig, identity: String) throws {
    let frameworksPath = appPath.appendingPathComponent("Contents/Frameworks")
    let frameworks = try? fileManager.contentsOfDirectory(
        at: frameworksPath, includingPropertiesForKeys: nil)
    guard let frameworks else {
        return
    }

    for framework in frameworks where framework.pathExtension == "framework" {
        try signPath(
            framework,
            identity: identity,
            identifier:
                "\(signing.bundleIdentifierPrefix).\(framework.deletingPathExtension().lastPathComponent)"
        )
    }

    let macOSPath = appPath.appendingPathComponent("Contents/MacOS")
    let binaries = try fileManager.contentsOfDirectory(
        at: macOSPath, includingPropertiesForKeys: nil)
    for binary in binaries where binary.pathExtension == "dylib" {
        try signPath(
            binary,
            identity: identity,
            identifier:
                "\(signing.bundleIdentifierPrefix).\(binary.deletingPathExtension().lastPathComponent)"
        )
    }
}

func signPath(_ path: URL, identity: String, identifier: String, entitlements: URL? = nil) throws {
    guard fileManager.fileExists(atPath: path.path) else {
        throw ToolError.failure("signing target not found: \(path.path)")
    }

    var arguments = [
        "--force",
        "--sign",
        identity,
        "--identifier",
        identifier,
        "--options",
        "runtime",
        "--timestamp",
    ]
    if let entitlements {
        arguments.append(contentsOf: ["--entitlements", entitlements.path])
    }
    arguments.append(path.path)
    try run("codesign", arguments)
    try run("codesign", ["--verify", "--strict", "--verbose=2", path.path])
}
func signingCheck() throws {
    let config = try signingConfig()
    try requireSigningIdentity(config)
    let daemon = productsDirectory.appendingPathComponent(daemonProductName)
    let app = macAppPath(configuration: "Debug")
    if fileManager.fileExists(atPath: daemon.path) {
        try run("codesign", ["--verify", "--strict", "--verbose=2", daemon.path])
    }
    if fileManager.fileExists(atPath: app.path) {
        try run("codesign", ["--verify", "--strict", "--deep", "--verbose=2", app.path])
    }
}

func notarySetup() throws {
    let config = try signingConfig()
    if notaryProfileExists(config.notaryProfile) {
        return
    }

    let values = try signingValues()
    let keyIdentifier = try values.required("APPLE_API_KEY_ID")
    let issuerIdentifier = try values.required("APPLE_API_ISSUER_ID")
    guard fileManager.fileExists(atPath: config.notaryKeyPath.path) else {
        throw ToolError.failure("notary key not found: \(config.notaryKeyPath.path)")
    }

    try run(
        "xcrun",
        [
            "notarytool",
            "store-credentials",
            config.notaryProfile,
            "--key",
            config.notaryKeyPath.path,
            "--key-id",
            keyIdentifier,
            "--issuer",
            issuerIdentifier,
        ],
        failureMessage: "xcrun notarytool store-credentials <profile> failed"
    )
}

func notarizeCheck() throws {
    let config = try signingConfig()
    let arguments = try notaryCredentialArguments(config)
    let result = try capture(
        "xcrun",
        ["notarytool", "history"] + arguments + ["--output-format", "json"],
        echoOutput: false
    )
    guard result.status == 0 else {
        throw ToolError.failure("notary credentials are not available")
    }
}

func notarizeMacApp(configuration: String) throws {
    let config = try signingConfig()
    let notaryArguments = try notaryCredentialArguments(config)

    try buildProject(target: .all, configuration: configuration)
    let appPath = macAppPath(configuration: configuration)
    guard fileManager.fileExists(atPath: appPath.path) else {
        throw ToolError.failure("built app not found: \(appPath.path)")
    }

    let notarizationDirectory = productsDirectory.appendingPathComponent("Notarization")
    try fileManager.createDirectory(at: notarizationDirectory, withIntermediateDirectories: true)

    let archivePath = notarizationDirectory.appendingPathComponent(
        "CellTunnelMac-\(configuration).zip")
    if fileManager.fileExists(atPath: archivePath.path) {
        try fileManager.removeItem(at: archivePath)
    }

    try run("ditto", ["-c", "-k", "--keepParent", appPath.path, archivePath.path])
    try run(
        "xcrun",
        ["notarytool", "submit", archivePath.path] + notaryArguments + ["--wait"],
        failureMessage: "xcrun notarytool submit <archive> failed"
    )
    try run("xcrun", ["stapler", "staple", appPath.path])
    try run("xcrun", ["stapler", "validate", appPath.path])
    try run("spctl", ["--assess", "--type", "execute", "--verbose=4", appPath.path])
}

func notaryCredentialArguments(_ config: SigningConfig) throws -> [String] {
    if notaryProfileExists(config.notaryProfile) {
        return ["--keychain-profile", config.notaryProfile]
    }

    let values = try signingValues()
    let keyIdentifier = try values.required("APPLE_API_KEY_ID")
    let issuerIdentifier = try values.required("APPLE_API_ISSUER_ID")
    guard fileManager.fileExists(atPath: config.notaryKeyPath.path) else {
        throw ToolError.failure("notary key not found: \(config.notaryKeyPath.path)")
    }

    return [
        "--key", config.notaryKeyPath.path, "--key-id", keyIdentifier, "--issuer", issuerIdentifier,
    ]
}

func notaryProfileExists(_ profile: String) -> Bool {
    let result = try? capture(
        "xcrun",
        ["notarytool", "history", "--keychain-profile", profile, "--output-format", "json"],
        echoOutput: false
    )
    return result?.status == 0
}

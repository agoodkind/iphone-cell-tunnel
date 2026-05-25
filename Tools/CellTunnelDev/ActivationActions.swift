import CellTunnelLog
import Foundation

enum ActivationActions {}

private let activationLogger = CellTunnelLog.logger(category: .build)

func activateTarget(_ target: ActivationTarget, configuration: String) throws {
    switch target {
    case .mac:
        try activateMacApp(configuration: configuration)
    case .iphone:
        try activatePhoneDevice(configuration: configuration)
    case .iphoneSimulator:
        try activatePhoneSimulator(configuration: configuration)
    }
}

func activateMacApp(configuration: String) throws {
    let appPath = macAppPath(configuration: configuration)
    guard fileManager.fileExists(atPath: appPath.path) else {
        throw ToolError.failure("built app not found: \(appPath.path)")
    }

    _ = try capture("pkill", ["-x", "CellTunnelMac"], echoOutput: false)
    try run("open", ["-n", appPath.path, "--args", macActivationArgument])
}

func refreshMacHelper(configuration: String) throws {
    try installMacHelper(configuration: configuration)
}

func installMacHelper(configuration: String) throws {
    let expectedAppPath = macAppPath(configuration: configuration).standardizedFileURL
    guard fileManager.fileExists(atPath: expectedAppPath.path) else {
        throw ToolError.failure("built app not found: \(expectedAppPath.path)")
    }
    let expectedHelperPath = expectedAppPath.appendingPathComponent(helperExecutableRelativePath)
    let expectedHelperFingerprint = try helperFingerprint(at: expectedHelperPath)
    let previousHelperProcessID = currentHelperProcessID()

    uninstallMacHelper()
    try installMacAppBundle(from: expectedAppPath)
    try registerInstalledMacHelper()

    let deadline = ContinuousClock.now + helperRefreshTimeout
    while ContinuousClock.now < deadline {
        let verification = currentInstalledHelperVerification(
            expectedHelperFingerprint: expectedHelperFingerprint,
            previousProcessID: previousHelperProcessID
        )
        if verification.isVerifiedCurrentBuild {
            return
        }
        try throwIfHelperVerificationIsStale(
            verification,
            expectedHelperFingerprint: expectedHelperFingerprint
        )
        waitForHelperVerificationPollInterval()
    }

    throw ToolError.failure(
        """
        helper verification timed out target=\(helperServiceTarget) \
        expected_bundle=\(expectedAppPath.path) \
        expected_fingerprint=\(expectedHelperFingerprint)
        """
    )
}

func uninstallMacHelper() {
    activationLogger.notice("helper uninstall removing registered launchd and app artifacts")
    _ = runBestEffort("pkill", ["-x", "CellTunnelMac"])
    _ = runBestEffort("sudo", ["launchctl", "bootout", "system/\(helperServiceLabel)"])
    _ = runBestEffort("sudo", ["sfltool", "resetbtm"])
    _ = runBestEffort(
        "sudo",
        ["rm", "-f", "/Library/LaunchDaemons/\(daemonLaunchDaemonPlistName)"])
    _ = runBestEffort(
        "sudo",
        ["rm", "-f", "/Library/PrivilegedHelperTools/\(helperServiceLabel)"])
    _ = runBestEffort("sudo", ["rm", "-rf", installedMacAppPath.path])
}

func installMacAppBundle(from sourceAppPath: URL) throws {
    let installedParentPath = installedMacAppPath.deletingLastPathComponent().path
    try run("sudo", ["rm", "-rf", installedMacAppPath.path])
    try run("sudo", ["cp", "-R", sourceAppPath.path, installedParentPath])
    try run("sudo", ["chown", "-R", "root:wheel", installedMacAppPath.path])
}

func registerInstalledMacHelper() throws {
    let executablePath =
        installedMacAppPath
        .appendingPathComponent("Contents/MacOS/CellTunnelMac")
    guard fileManager.fileExists(atPath: executablePath.path) else {
        throw ToolError.failure("installed app executable not found: \(executablePath.path)")
    }
    try run("open", ["-W", "-n", installedMacAppPath.path, "--args", macHelperInstallArgument])
}

func activatePhoneDevice(configuration: String) throws {
    try installBuiltPhoneDevice(configuration: configuration)
    try launchInstalledPhoneDevice()
}

func activatePhoneSimulator(configuration: String) throws {
    let simulatorIdentifier = try selectedPhoneSimulatorIdentifier()
    let appPath = phoneSimulatorAppPath(configuration: configuration)
    guard fileManager.fileExists(atPath: appPath.path) else {
        throw ToolError.failure("built phone simulator app not found: \(appPath.path)")
    }

    try bootPhoneSimulator(identifier: simulatorIdentifier)
    try run("xcrun", ["simctl", "install", simulatorIdentifier, appPath.path])
    try run(
        "xcrun",
        [
            "simctl",
            "launch",
            "--terminate-running-process",
            simulatorIdentifier,
            phoneBundleIdentifier,
            phoneActivationArgument,
        ]
    )
}

func phoneSimulatorAppPath(configuration: String) -> URL {
    xcodeConfigurationBuildDirectory(
        configuration: configuration,
        platformName: iOSSimulatorPlatformName
    ).appendingPathComponent("CellTunnelPhone.app")
}

struct SimulatorDeviceList: Decodable {
    let devices: [String: [SimulatorDevice]]
}

struct SimulatorDevice: Decodable {
    let udid: String
    let isAvailable: Bool
    let deviceTypeIdentifier: String
    let lastBootedAt: String?
    let name: String
    let state: String
}

struct SimulatorRuntimeList: Decodable {
    let runtimes: [SimulatorRuntime]
}

struct SimulatorRuntime: Decodable {
    let identifier: String
    let isAvailable: Bool
    let name: String
    let supportedDeviceTypes: [SimulatorSupportedDeviceType]
    let version: String
}

struct SimulatorSupportedDeviceType: Decodable {
    let identifier: String
    let name: String
    let productFamily: String
}

struct AvailableSimulator {
    let runtimeIdentifier: String
    let device: SimulatorDevice
}

func phoneDeviceAppPath(configuration: String) -> URL {
    xcodeConfigurationBuildDirectory(
        configuration: configuration,
        platformName: iOSDevicePlatformName
    ).appendingPathComponent("CellTunnelPhone.app")
}

func launchInstalledPhoneDevice() throws {
    let deviceIdentifier = try selectedPhoneDeviceIdentifier()
    try run(
        "xcrun",
        [
            "devicectl",
            "device",
            "process",
            "launch",
            "--terminate-existing",
            "--device",
            deviceIdentifier,
            phoneBundleIdentifier,
            phoneActivationArgument,
        ]
    )
}

func selectedPhoneSimulatorIdentifier() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    if let simulatorIdentifier = environment["IOS_SIMULATOR_ID"], !simulatorIdentifier.isEmpty {
        return simulatorIdentifier
    }
    if let destination = environment["IOS_SIMULATOR_DESTINATION"], !destination.isEmpty {
        if let simulatorIdentifier = try simulatorIdentifier(from: destination) {
            return simulatorIdentifier
        }
    }

    let bootedSimulators = try availablePhoneSimulators().filter { simulator in
        simulator.device.state == "Booted"
    }
    if let simulator = preferredSimulator(from: bootedSimulators) {
        return simulator.device.udid
    }

    return try createPhoneSimulator()
}

func simulatorIdentifier(from destination: String) throws -> String? {
    var components: [String: String] = [:]
    for part in destination.split(separator: ",") {
        let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmedPart.split(separator: "=", maxSplits: 1)
        guard pieces.count == 2 else {
            continue
        }
        components[String(pieces[0])] = String(pieces[1])
    }

    if let simulatorIdentifier = components["id"], !simulatorIdentifier.isEmpty {
        return simulatorIdentifier
    }
    guard let simulatorName = components["name"], !simulatorName.isEmpty else {
        return nil
    }

    let matchingSimulators = try availablePhoneSimulators().filter { simulator in
        simulator.device.name == simulatorName
    }
    guard let simulator = preferredSimulator(from: matchingSimulators) else {
        throw ToolError.failure("no available iPhone simulator named \(simulatorName)")
    }
    return simulator.device.udid
}

func availablePhoneSimulators() throws -> [AvailableSimulator] {
    let result = try capture(
        "xcrun",
        ["simctl", "list", "-j", "devices", "available"],
        echoOutput: false
    )
    guard result.status == 0 else {
        throw ToolError.failure("xcrun simctl list -j devices available failed")
    }

    let deviceList = try JSONDecoder().decode(
        SimulatorDeviceList.self, from: Data(result.output.utf8))
    return deviceList.devices.flatMap { runtimeIdentifier, devices in
        devices.compactMap { device in
            guard device.isAvailable, device.name.hasPrefix("iPhone") else {
                return nil
            }
            return AvailableSimulator(runtimeIdentifier: runtimeIdentifier, device: device)
        }
    }
}

func preferredSimulator(from simulators: [AvailableSimulator]) -> AvailableSimulator? {
    simulators.max { lhs, rhs in
        isPreferredSimulator(lhs: rhs, rhs: lhs)
    }
}

func isPreferredSimulator(lhs: AvailableSimulator, rhs: AvailableSimulator) -> Bool {
    let runtimeComparison = compareVersionComponents(
        lhs: simulatorRuntimeVersion(from: lhs.runtimeIdentifier),
        rhs: simulatorRuntimeVersion(from: rhs.runtimeIdentifier)
    )
    if runtimeComparison != 0 {
        return runtimeComparison > 0
    }

    let lhsBootedAt = lhs.device.lastBootedAt ?? ""
    let rhsBootedAt = rhs.device.lastBootedAt ?? ""
    if lhsBootedAt != rhsBootedAt {
        return lhsBootedAt > rhsBootedAt
    }

    return lhs.device.udid > rhs.device.udid
}

func simulatorRuntimeVersion(from runtimeIdentifier: String) -> [Int] {
    guard let range = runtimeIdentifier.range(of: "iOS-") else {
        return [0]
    }
    return runtimeIdentifier[range.upperBound...]
        .split(separator: "-")
        .compactMap { component in
            Int(component)
        }
}

func createPhoneSimulator() throws -> String {
    let runtime = try preferredSimulatorRuntime()
    let supportedPhoneDeviceTypes = runtime.supportedDeviceTypes.filter { deviceType in
        deviceType.productFamily == "iPhone"
    }
    guard let deviceType = supportedPhoneDeviceTypes.first else {
        throw ToolError.failure(
            "no supported iPhone simulator device type found for \(runtime.name)")
    }

    let simulatorName = "\(autoCreatedSimulatorNamePrefix) \(String(UUID().uuidString.prefix(8)))"
    let result = try capture(
        "xcrun",
        ["simctl", "create", simulatorName, deviceType.identifier, runtime.identifier],
        echoOutput: false
    )
    guard result.status == 0 else {
        throw ToolError.failure("xcrun simctl create failed")
    }

    let simulatorIdentifier = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !simulatorIdentifier.isEmpty else {
        throw ToolError.failure("created simulator identifier was empty")
    }
    return simulatorIdentifier
}

func preferredSimulatorRuntime() throws -> SimulatorRuntime {
    let result = try capture(
        "xcrun",
        ["simctl", "list", "-j", "runtimes", "available"],
        echoOutput: false
    )
    guard result.status == 0 else {
        throw ToolError.failure("xcrun simctl list -j runtimes available failed")
    }

    let runtimeList = try JSONDecoder().decode(
        SimulatorRuntimeList.self,
        from: Data(result.output.utf8)
    )
    let availableRuntimes = runtimeList.runtimes.filter { runtime in
        runtime.isAvailable && runtime.identifier.contains(".SimRuntime.iOS-")
    }
    guard
        let runtime = availableRuntimes.max(by: { lhs, rhs in
            compareVersionComponents(lhs: lhs.versionComponents, rhs: rhs.versionComponents) < 0
        })
    else {
        throw ToolError.failure("no available iOS simulator runtime found")
    }
    return runtime
}

func bootPhoneSimulator(identifier: String) throws {
    try run("xcrun", ["simctl", "bootstatus", identifier, "-b"])
}

extension SimulatorRuntime {
    var versionComponents: [Int] {
        version.split(separator: ".").compactMap { component in
            Int(component)
        }
    }
}

func compareVersionComponents(lhs: [Int], rhs: [Int]) -> Int {
    let maxCount = max(lhs.count, rhs.count)
    for index in 0..<maxCount {
        let lhsValue = index < lhs.count ? lhs[index] : 0
        let rhsValue = index < rhs.count ? rhs[index] : 0
        if lhsValue != rhsValue {
            return lhsValue < rhsValue ? -1 : 1
        }
    }
    return 0
}

func currentHelperProcessID() -> Int? {
    activationLogger.notice(
        "helper verification querying launchctl target=\(helperServiceTarget, privacy: .public)")
    let result: CommandResult
    do {
        result = try capture("launchctl", ["print", helperServiceTarget], echoOutput: false)
    } catch {
        activationLogger.error(
            "helper verification launchctl query failed error=\(error.localizedDescription, privacy: .public)"
        )
        return nil
    }
    guard result.status == 0 else {
        return nil
    }
    guard let processIDRange = result.output.range(of: "pid = ") else {
        return nil
    }
    let pidSuffix = result.output[processIDRange.upperBound...]
    let processIDText = pidSuffix.prefix(while: \.isNumber)
    guard let processID = Int(processIDText) else {
        return nil
    }
    return processID
}

func waitForHelperVerificationPollInterval() {
    activationLogger.debug("helper verification waiting for next poll interval")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
}

func throwIfHelperVerificationIsStale(
    _ verification: HelperVerification,
    expectedHelperFingerprint: String
) throws {
    activationLogger.notice(
        "helper verification evaluating registration expectedFingerprint=\(expectedHelperFingerprint, privacy: .public)"
    )
    switch verification {
    case .staleRegistration(let registeredState):
        activationLogger.error(
            """
            helper verification detected stale registration \
            appPath=\(registeredState.appPath.path, privacy: .public) \
            fingerprint=\(registeredState.helperFingerprint, privacy: .public) \
            expectedFingerprint=\(expectedHelperFingerprint, privacy: .public)
            """
        )
        throw ToolError.failure(
            """
            helper is registered from \(registeredState.appPath.path) \
            fingerprint=\(registeredState.helperFingerprint) \
            expected_fingerprint=\(expectedHelperFingerprint); \
            run make install-helper to reinstall the privileged helper from the current build
            """
        )
    case .currentBuild, .notRegistered, .registeredButUnavailable:
        return
    }
}

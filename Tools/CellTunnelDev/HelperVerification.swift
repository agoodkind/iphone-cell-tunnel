import CellTunnelLog
import CryptoKit
import Foundation

private let helperVerificationLogger = CellTunnelLog.logger(category: .build)

struct RegisteredBinaryState {
    let appPath: URL
    let binaryFingerprint: String
}

enum BinaryVerification {
    case currentBuild(RegisteredBinaryState)
    case notRegistered
    case registeredButUnavailable(RegisteredBinaryState)
    case staleRegistration(RegisteredBinaryState)

    var isVerifiedCurrentBuild: Bool {
        if case .currentBuild = self {
            return true
        }
        return false
    }
}

struct InstallVerification {
    let helper: BinaryVerification
    let daemon: BinaryVerification

    var isVerifiedCurrentBuild: Bool {
        helper.isVerifiedCurrentBuild && daemon.isVerifiedCurrentBuild
    }
}

func currentInstalledVerification(
    expectedHelperFingerprint: String,
    expectedDaemonFingerprint: String,
    previousHelperProcessID: Int?,
    previousDaemonProcessID: Int?
) -> InstallVerification {
    let helper = currentInstalledBinaryVerification(
        relativePath: helperExecutableRelativePath,
        expectedFingerprint: expectedHelperFingerprint,
        serviceTarget: helperServiceTarget,
        previousProcessID: previousHelperProcessID
    )
    let daemon = currentInstalledBinaryVerification(
        relativePath: daemonExecutableRelativePath,
        expectedFingerprint: expectedDaemonFingerprint,
        serviceTarget: daemonServiceTarget(),
        previousProcessID: previousDaemonProcessID
    )
    return InstallVerification(helper: helper, daemon: daemon)
}

func currentInstalledBinaryVerification(
    relativePath: String,
    expectedFingerprint: String,
    serviceTarget: String,
    previousProcessID: Int?
) -> BinaryVerification {
    let installedAppPath = installedMacAppPath.standardizedFileURL
    let installedBinaryPath = installedAppPath.appendingPathComponent(relativePath)
    let installedFingerprint: String
    do {
        installedFingerprint = try helperFingerprint(at: installedBinaryPath)
    } catch {
        helperVerificationLogger.notice(
            """
            binary verification found no installed binary \
            path=\(installedBinaryPath.path, privacy: .public) \
            error=\(error.localizedDescription, privacy: .public)
            """
        )
        return .notRegistered
    }

    let installedState = RegisteredBinaryState(
        appPath: installedAppPath,
        binaryFingerprint: installedFingerprint
    )
    guard let processID = launchctlProcessID(target: serviceTarget) else {
        return .registeredButUnavailable(installedState)
    }
    if let previousProcessID, processID == previousProcessID {
        helperVerificationLogger.notice(
            """
            binary verification rejected previous pid \
            target=\(serviceTarget, privacy: .public) \
            pid=\(processID, privacy: .public)
            """
        )
        return .registeredButUnavailable(installedState)
    }
    guard installedFingerprint == expectedFingerprint else {
        return .staleRegistration(installedState)
    }
    return .currentBuild(installedState)
}

func helperFingerprint(at url: URL) throws -> String {
    guard fileManager.fileExists(atPath: url.path) else {
        throw ToolError.failure("binary not found: \(url.path)")
    }
    let binaryData = try Data(contentsOf: url)
    let digest = SHA256.hash(data: binaryData)
    let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
    return String(hexDigest.prefix(12))
}

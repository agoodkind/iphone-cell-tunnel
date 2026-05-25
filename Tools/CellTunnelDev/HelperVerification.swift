import CellTunnelLog
import CryptoKit
import Foundation

private let helperVerificationLogger = CellTunnelLog.logger(category: .build)

struct RegisteredHelperState {
    let appPath: URL
    let helperFingerprint: String
}

enum HelperVerification {
    case currentBuild(RegisteredHelperState)
    case notRegistered
    case registeredButUnavailable(RegisteredHelperState)
    case staleRegistration(RegisteredHelperState)

    var isVerifiedCurrentBuild: Bool {
        if case .currentBuild = self {
            return true
        }
        return false
    }
}

func currentInstalledHelperVerification(
    expectedHelperFingerprint: String,
    previousProcessID: Int?
) -> HelperVerification {
    let installedAppPath = installedMacAppPath.standardizedFileURL
    let installedHelperPath = installedAppPath.appendingPathComponent(
        helperExecutableRelativePath
    )
    let installedHelperFingerprint: String
    do {
        installedHelperFingerprint = try helperFingerprint(at: installedHelperPath)
    } catch {
        helperVerificationLogger.notice(
            """
            helper verification found no installed helper \
            path=\(installedHelperPath.path, privacy: .public) \
            error=\(error.localizedDescription, privacy: .public)
            """
        )
        return .notRegistered
    }

    let installedState = RegisteredHelperState(
        appPath: installedAppPath,
        helperFingerprint: installedHelperFingerprint
    )
    guard let processID = currentHelperProcessID() else {
        return .registeredButUnavailable(installedState)
    }
    if let previousProcessID, processID == previousProcessID {
        helperVerificationLogger.notice(
            """
            helper verification rejected previous helper pid \
            pid=\(processID, privacy: .public)
            """
        )
        return .registeredButUnavailable(installedState)
    }
    guard installedHelperFingerprint == expectedHelperFingerprint else {
        return .staleRegistration(installedState)
    }
    return .currentBuild(installedState)
}

func helperFingerprint(at url: URL) throws -> String {
    guard fileManager.fileExists(atPath: url.path) else {
        throw ToolError.failure("helper binary not found: \(url.path)")
    }
    let helperData = try Data(contentsOf: url)
    let digest = SHA256.hash(data: helperData)
    let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
    return String(hexDigest.prefix(12))
}

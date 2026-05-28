import CellTunnelCore
import CellTunnelLog
import CryptoKit
import Foundation

private let helperVerificationLogger = CellTunnelLog.logger(category: .build)

struct InstalledDaemonState {
    let appPath: URL
    let binaryFingerprint: String
}

enum InstalledDaemonVerification {
    case currentBuild(InstalledDaemonState)
    case notRegistered
    case staleRegistration(InstalledDaemonState)

    var isVerifiedCurrentBuild: Bool {
        if case .currentBuild = self {
            return true
        }
        return false
    }
}

func currentInstalledDaemonVerification(
    expectedDaemonFingerprint: String
) -> InstalledDaemonVerification {
    let installedAppPath = installedMacAppPath.standardizedFileURL
    let installedBinaryPath = installedAppPath.appendingPathComponent(daemonExecutableRelativePath)
    let installedFingerprint: String
    do {
        installedFingerprint = try helperFingerprint(at: installedBinaryPath)
    } catch {
        helperVerificationLogger.notice(
            """
            daemon verification found no installed binary \
            path=\(installedBinaryPath.path, privacy: .public) \
            error=\(error.localizedDescription, privacy: .public)
            """
        )
        return .notRegistered
    }

    let installedState = InstalledDaemonState(
        appPath: installedAppPath,
        binaryFingerprint: installedFingerprint
    )
    guard installedFingerprint == expectedDaemonFingerprint else {
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

enum DaemonPingError: LocalizedError {
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .failed(let error):
            return "daemon XPC ping failed: \(error.localizedDescription)"
        }
    }
}

func pingDaemonOverXPC() async throws {
    let client = TunnelControlClient()
    do {
        _ = try await client.status()
        await client.shutdown()
    } catch {
        await client.shutdown()
        throw DaemonPingError.failed(error)
    }
}

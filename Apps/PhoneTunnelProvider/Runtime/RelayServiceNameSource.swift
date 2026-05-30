import CellTunnelCore
import Foundation

/// Resolves the Bonjour service name the relay listener and control listener
/// advertise. Reads the app-group device name the iOS app stored, and falls back
/// to the process host name when no shared name is present.
func resolvedRelayServiceName(
    defaults: UserDefaults? = UserDefaults(suiteName: cellTunnelAppGroupIdentifier)
) -> String {
    if let stored = defaults?.string(forKey: relayServiceDeviceNameDefaultsKey) {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return ProcessInfo.processInfo.hostName
}

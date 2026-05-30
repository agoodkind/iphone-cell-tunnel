import CellTunnelCore
import Foundation

/// App-group `UserDefaults` key the iOS app writes the user-visible device name
/// to so the background extension can advertise the same Bonjour service name.
/// The extension target has no UIKit, so it cannot read `UIDevice.current.name`;
/// the app writes the name into the shared app group and the provider reads it
/// here, falling back to `ProcessInfo.processInfo.hostName` when the app has not
/// written one yet.
let relayServiceDeviceNameDefaultsKey = "io.goodkind.celltunnel.relay.deviceName"

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

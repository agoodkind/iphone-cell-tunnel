import Foundation
import Network

public let relayListenerPortDefaultsKey = "io.goodkind.celltunnel.relay.port"
public let relayListenerPortDefaultValue: UInt16 = 51_821
public let relayListenerPortLaunchArgument = "--cell-tunnel-port"

public func resolvedRelayListenerPort(
    defaults: UserDefaults = .standard
) -> NWEndpoint.Port {
    let stored = defaults.integer(forKey: relayListenerPortDefaultsKey)
    if stored >= 1, stored <= Int(UInt16.max) {
        if let port = NWEndpoint.Port(rawValue: UInt16(stored)) {
            return port
        }
    }
    return NWEndpoint.Port(rawValue: relayListenerPortDefaultValue) ?? .any
}

public func storeRelayListenerPort(
    _ port: UInt16,
    defaults: UserDefaults = .standard
) {
    defaults.set(Int(port), forKey: relayListenerPortDefaultsKey)
}

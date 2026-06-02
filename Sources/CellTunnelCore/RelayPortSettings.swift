//
//  RelayPortSettings.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Network

public let relayListenerPortDefaultsKey = "io.goodkind.celltunnel.relay.port"
public let relayListenerPortDefaultValue: UInt16 = 51_821
public let relayListenerPortLaunchArgument = "--cell-tunnel-port"

// App-group key the iOS app writes the user-visible device name to so the
// background extension, which has no UIKit, advertises the same Bonjour service
// name instead of the process host name.
public let relayServiceDeviceNameDefaultsKey = "io.goodkind.celltunnel.relay.deviceName"

public func storeRelayServiceDeviceName(
    _ name: String,
    defaults: UserDefaults = .standard
) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return
    }
    defaults.set(trimmed, forKey: relayServiceDeviceNameDefaultsKey)
}

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

import CellTunnelCore
import Foundation

public let wireGuardServerHostDefaultsKey = "io.goodkind.celltunnel.wireguard.server.host"
public let wireGuardServerPortDefaultsKey = "io.goodkind.celltunnel.wireguard.server.port"
public let wireGuardServerFamilyDefaultsKey = "io.goodkind.celltunnel.wireguard.server.family"

public let wireGuardServerHostLaunchArgument = "--cell-tunnel-wireguard-server-host"
public let wireGuardServerPortLaunchArgument = "--cell-tunnel-wireguard-server-port"
public let wireGuardServerFamilyLaunchArgument = "--cell-tunnel-wireguard-server-family"

public func resolvedWireGuardServerEndpoint(
    defaults: UserDefaults = .standard
) -> RelayEndpoint? {
    guard let host = defaults.string(forKey: wireGuardServerHostDefaultsKey), !host.isEmpty else {
        return nil
    }
    let storedPort = defaults.integer(forKey: wireGuardServerPortDefaultsKey)
    guard storedPort >= 1, storedPort <= Int(UInt16.max) else {
        return nil
    }
    let family = resolvedAddressFamily(defaults: defaults)
    return RelayEndpoint(addressFamily: family, host: host, port: UInt16(storedPort))
}

public func storeWireGuardServerEndpoint(
    host: String,
    port: UInt16,
    addressFamily: RelayAddressFamily,
    defaults: UserDefaults = .standard
) {
    defaults.set(host, forKey: wireGuardServerHostDefaultsKey)
    defaults.set(Int(port), forKey: wireGuardServerPortDefaultsKey)
    defaults.set(Int(addressFamily.rawValue), forKey: wireGuardServerFamilyDefaultsKey)
}

private func resolvedAddressFamily(defaults: UserDefaults) -> RelayAddressFamily {
    let stored = defaults.integer(forKey: wireGuardServerFamilyDefaultsKey)
    if let family = RelayAddressFamily(rawValue: UInt8(clamping: stored)) {
        return family
    }
    return .ipv4
}

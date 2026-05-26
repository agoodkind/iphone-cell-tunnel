import Foundation

struct RoutePlan: Equatable, Sendable {
    let interfaceName: String
    let prefixes: [AddressPrefix]
}

enum RoutePlanBuilder {
    static func build(from config: WireGuardClientConfig, interfaceName: String) -> RoutePlan {
        let normalised = config.peer.allowedIPs.map { prefix -> AddressPrefix in
            AddressPrefix(
                family: prefix.family,
                address: prefix.address,
                prefixLength: prefix.prefixLength
            )
        }
        return RoutePlan(interfaceName: interfaceName, prefixes: normalised)
    }
}

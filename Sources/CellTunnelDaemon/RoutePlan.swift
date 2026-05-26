import CellTunnelCore
import Foundation

enum AddressFamily: String, Sendable {
    case ipv4
    case ipv6
}

struct AddressPrefix: Sendable, Equatable {
    let family: AddressFamily
    let address: String
    let prefixLength: Int

    var helperPrefix: HelperAddressPrefix {
        let helperFamily: HelperAddressFamily = family == .ipv4 ? .ipv4 : .ipv6
        return HelperAddressPrefix(
            family: helperFamily,
            address: address,
            prefixLength: prefixLength
        )
    }
}

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

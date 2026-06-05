//
//  NWEndpoint+AddressPair.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Network

// MARK: - NWEndpoint address pair

extension NWEndpoint {
    /// The address pair for a host endpoint: the IPv4 or IPv6 literal it carries,
    /// with the IPv6 scope suffix stripped. A named or non-host endpoint yields an
    /// empty pair. The carrying link's peer address reads through this on both hosts,
    /// so the connection's remote endpoint maps to a pair one way.
    public var addressPair: AddressPair {
        guard case .hostPort(let host, _) = self else {
            return .empty
        }
        switch host {
        case .ipv4(let address):
            return AddressPair(ipv4: NWEndpoint.strippingScope("\(address)"))
        case .ipv6(let address):
            return AddressPair(ipv6: NWEndpoint.strippingScope("\(address)"))
        case .name:
            return .empty
        @unknown default:
            return .empty
        }
    }

    private static func strippingScope(_ value: String) -> String {
        guard let separator = value.firstIndex(of: "%") else {
            return value
        }
        return String(value[..<separator])
    }
}

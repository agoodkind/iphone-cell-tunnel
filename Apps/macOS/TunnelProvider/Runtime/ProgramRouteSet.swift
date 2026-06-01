//
//  ProgramRouteSet.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
//

import Foundation
import NetworkExtension

// MARK: - Constants

private let ipv4BitWidth = 32
private let ipv4OctetCount = 4
private let bitsPerOctet = 8
private let octetMask: UInt32 = 0xFF

// MARK: - ProgramRouteSet

/// Converts the program's scoped destination prefixes into the operating-system
/// routes the tunnel captures. The route gate installs these independent of the
/// WireGuard cryptokey allowed IPs, so the captured route set stays scoped.
enum ProgramRouteSet {
    /// The IPv4 and IPv6 routes for a list of address prefixes.
    static func routes(
        from prefixes: [AddressPrefix]
    ) -> (ipv4: [NEIPv4Route], ipv6: [NEIPv6Route]) {
        var ipv4Routes: [NEIPv4Route] = []
        var ipv6Routes: [NEIPv6Route] = []
        for prefix in prefixes {
            switch prefix.family {
            case .ipv4:
                ipv4Routes.append(
                    NEIPv4Route(
                        destinationAddress: prefix.address,
                        subnetMask: ipv4SubnetMask(prefixLength: prefix.prefixLength)
                    )
                )
            case .ipv6:
                ipv6Routes.append(
                    NEIPv6Route(
                        destinationAddress: prefix.address,
                        networkPrefixLength: NSNumber(value: prefix.prefixLength)
                    )
                )
            }
        }
        return (ipv4Routes, ipv6Routes)
    }

    // MARK: - Helpers

    /// The dotted-decimal subnet mask for an IPv4 prefix length, for example
    /// length 24 to "255.255.255.0".
    private static func ipv4SubnetMask(prefixLength: Int) -> String {
        let clampedLength = max(0, min(prefixLength, ipv4BitWidth))
        let mask: UInt32 = clampedLength == 0 ? 0 : UInt32.max << (ipv4BitWidth - clampedLength)
        var octets: [String] = []
        for octetIndex in 0..<ipv4OctetCount {
            let shift = (ipv4OctetCount - 1 - octetIndex) * bitsPerOctet
            octets.append(String((mask >> UInt32(shift)) & octetMask))
        }
        return octets.joined(separator: ".")
    }
}

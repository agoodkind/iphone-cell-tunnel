//
//  AddressPair.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - AddressPair

/// One IPv6 and one IPv4 address, either of which may be absent. Every place the
/// status carries a v6/v4 pair uses this one type, so the snapshot, the control
/// link, and the screen read the same shape and one row builder renders them all.
public struct AddressPair: Codable, Sendable, Equatable {
    public var ipv4: String?
    public var ipv6: String?

    public init(ipv4: String? = nil, ipv6: String? = nil) {
        self.ipv4 = AddressPair.normalized(ipv4)
        self.ipv6 = AddressPair.normalized(ipv6)
    }

    /// A pair with both families absent.
    public static let empty = AddressPair()

    /// Whether both families are absent.
    public var isEmpty: Bool {
        ipv4 == nil && ipv6 == nil
    }

    /// The single address to show when one value is wanted, such as a link end that
    /// uses one family. IPv6 is preferred, since the Mac-to-iPhone link is IPv6
    /// link-local, falling back to IPv4.
    public var preferredAddress: String? {
        ipv6 ?? ipv4
    }

    /// Trims whitespace and treats an empty string as absent, so a blank wire value
    /// never reaches the screen as a present-but-empty address.
    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

//
//  AddressPrefix.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - AddressFamily

enum AddressFamily: String, Sendable {
    case ipv4
    case ipv6
}

// MARK: - AddressPrefix

struct AddressPrefix: Sendable, Equatable {
    let family: AddressFamily
    let address: String
    let prefixLength: Int
}

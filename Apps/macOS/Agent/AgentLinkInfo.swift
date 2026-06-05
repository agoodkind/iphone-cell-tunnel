//
//  AgentLinkInfo.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - AgentLinkInfo

/// The carrying link's interface, transport class, and addresses, written from the
/// relay bridge's egress callback and read into the served snapshot so the Mac
/// reports the same `Connection` rows the iPhone does.
struct AgentLinkInfo: Sendable {
    var interfaceName: String?
    var linkClass: RelayLinkClass?
    var localAddresses = AddressPair.empty
    var peerAddresses = AddressPair.empty
}

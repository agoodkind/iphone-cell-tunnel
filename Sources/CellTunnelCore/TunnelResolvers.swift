//
//  TunnelResolvers.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-28.
//  Copyright © 2026, all rights reserved.
//

import Network

/// Which of the resolvers a configuration names the tunnel may publish.
///
/// Only what the configuration names is eligible. Substituting an address when a
/// configuration names none would decide where a person's queries go on their
/// behalf, and name resolution is not what carries traffic: a configuration naming
/// no resolver still passes packets, and only names stop resolving through the
/// tunnel.
///
/// A named resolver is dropped when the tunnel holds no address in its family,
/// because it would then have no source address to be answered from and its queries
/// would leave over a physical interface.
public func publishableResolvers(
  named: [String],
  tunnelCarriesIPv4: Bool,
  tunnelCarriesIPv6: Bool
) -> [String] {
  named.filter { address in
    if IPv4Address(address) != nil {
      return tunnelCarriesIPv4
    }
    if IPv6Address(address) != nil {
      return tunnelCarriesIPv6
    }
    return false
  }
}

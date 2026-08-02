//
//  RelayDialTarget.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

// MARK: - relayDialTarget

/// Picks which discovered Mac the iPhone dials.
///
/// This decision existed twice with different rules. One copy dialled the first listed
/// Mac regardless of how many were visible, so a home with two Macs connected to
/// whichever one the network happened to list first. Abstaining while several are
/// visible is deliberate rather than an omission: only the person can say which Mac
/// carries their traffic. Keeping the rule here, where it is tested, is what stops a
/// second copy appearing again.
public func relayDialTarget(
  selectedServiceID: String?,
  services: [TunnelRelayService]
) -> String? {
  if let selectedServiceID, services.contains(where: { $0.id == selectedServiceID }) {
    return selectedServiceID
  }
  if services.count == 1 {
    return services.first?.id
  }
  return nil
}

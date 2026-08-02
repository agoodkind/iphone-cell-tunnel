//
//  AgentTunnelController+Readiness.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - Routing readiness

extension AgentTunnelController {
  /// Whether routing may start right now, enforced when a request arrives.
  ///
  /// Asks the listener directly, because a request is about to act on the answer.
  func currentRoutingStartReadiness() async -> RoutingStartReadiness {
    let hasPeer = await controlListener?.hasSelectedPeer() == true
    return routingStartReadiness(
      hasActiveConfig: hasResolvableActiveConfig, hasSelectedPeer: hasPeer)
  }

  /// The same verdict for the snapshot, read from the roster the listener publishes.
  ///
  /// The roster records which iPhone is selected and is readable without waiting on the
  /// listener, so building a snapshot does not queue behind it. Both answers come from
  /// one rule, so a client rendering a switch and the request that enforces it cannot
  /// disagree.
  func publishedRoutingStartReadiness() -> RoutingStartReadiness {
    let hasPeer = connectedPeers.withLock { $0.contains(where: \.isSelected) }
    return routingStartReadiness(
      hasActiveConfig: hasResolvableActiveConfig, hasSelectedPeer: hasPeer)
  }

  /// Where this daemon is between the two settled routing states.
  ///
  /// Said here rather than left for a client to work out, because a client can only work
  /// it out by counting readings, and it stops counting whenever it stops reading. An app
  /// put in the background mid-connect came back to a spinner frozen for the whole time
  /// it was away.
  func publishedRoutingPhase(routeState: TunnelRouteState) -> TunnelRoutingPhase {
    TunnelRoutingPhase.resolve(
      isRoutingEnabled: routingEnabled,
      areRoutesInstalled: routeState == .installed
    )
  }

  /// Whether a configuration is chosen and its text can still be read.
  private var hasResolvableActiveConfig: Bool {
    configStore.activeID.flatMap { configStore.text(forID: $0) } != nil
  }
}

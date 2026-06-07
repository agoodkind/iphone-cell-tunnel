//
//  PublicAddressExchange.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import Synchronization

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - PublicAddressExchange

/// Holds this host's and the peer's measured public addresses. It probes this
/// host's public address on demand and stores the peer's address received over the
/// control link. It owns no connection and no send path: each host probes on its
/// own triggers, sends the result over its own control link, and reads `resolved`
/// when it assembles a status snapshot. The iPhone engine and the Mac agent each
/// own one.
public final class PublicAddressExchange: @unchecked Sendable {
  // MARK: - Resolved

  /// This host's and the peer's measured public addresses.
  public struct Resolved: Sendable, Equatable {
    public var device: AddressPair
    public var peer: AddressPair

    public init(device: AddressPair = .empty, peer: AddressPair = .empty) {
      self.device = device
      self.peer = peer
    }
  }

  private struct State {
    var device = AddressPair.empty
    var peer = AddressPair.empty

    var resolved: Resolved {
      Resolved(device: device, peer: peer)
    }
  }

  private let probe: PublicAddressProbe
  private let state = Mutex(State())

  public init(probe: PublicAddressProbe = PublicAddressProbe()) {
    self.probe = probe
  }

  /// This host's and the peer's latest addresses, read where a snapshot is
  /// assembled.
  public var resolved: Resolved {
    state.withLock { $0.resolved }
  }

  // MARK: - Device

  /// Measures this host's public address over its current default path and stores
  /// it. Called on each trigger that can change the path: a control connection
  /// becoming ready, an egress path change, a routing change, and a periodic
  /// backstop. The caller sends the returned pair over its control link.
  public func probeDevice() async -> AddressPair {
    let pair = await probe.probe()
    state.withLock { $0.device = pair }
    logger.notice(
      """
      public address exchange measured device \
      ipv4=\(pair.ipv4 ?? "none", privacy: .public) \
      ipv6=\(pair.ipv6 ?? "none", privacy: .public)
      """
    )
    return pair
  }

  // MARK: - Peer

  /// Stores the peer's address received over the control link.
  public func received(_ peer: AddressPair) {
    state.withLock { $0.peer = peer }
  }

  /// Clears the peer's address when the control link to the peer drops, so a stale
  /// peer address does not linger after the peer is gone.
  public func clearPeer() {
    state.withLock { $0.peer = .empty }
  }
}

//
//  RelaySituation.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-05.
//  Copyright © 2026, all rights reserved.
//

// MARK: - RelaySituation

/// Which situation the machine is in, the one value a client renders its status from.
///
/// Two precedence chains decided this inside the app, over eight and five separate
/// flags, and the command-line tool could reach neither, so the two surfaces could
/// describe the same agent differently. The situation travels on the wire and each
/// client writes its own words for it, which keeps wording in the client while the
/// decision stays with the producer.
///
/// One set covers both producers. A situation only one of them can reach is simply
/// unreachable from the other's snapshot rather than absent from the type, which is
/// what lets one printed line serve both.
public enum RelaySituation: String, Codable, Equatable, Sendable {
  case connecting
  case failed
  case noActiveConfig = "no-active-config"
  case noAgent = "no-agent"
  case noConfigImported = "no-config-imported"
  case noPeerSelected = "no-peer-selected"
  case noPeersFound = "no-peers-found"
  /// This machine is not publishing the record a peer looks for, so it can never be
  /// found however long a person waits.
  case notDiscoverable = "not-discoverable"
  case notProvisioned = "not-provisioned"
  case readyToRoute = "ready-to-route"
  case routing
  case vpnProfileDisabled = "vpn-profile-disabled"
}

// MARK: - Mac

/// The Mac's situation. A failure wins, then the library must hold a configuration,
/// then the saved VPN profile must be switched on. The library comes before the
/// profile because deleting every configuration leaves the profile in place, and
/// re-enabling a profile with nothing to route accomplishes nothing.
///
/// An established peer link decides the rest before discovery, since a live link means
/// the machine is connected whether or not this side browsed for it. The split between
/// routing, connecting, and ready is the routing phase, never a local running flag.
/// Without a link, a Mac that is not advertising is unfindable rather than searching,
/// because only one of those ends on its own; otherwise no dialed-in iPhone is the
/// searching situation and a listed but unconnected one is the select situation.
///
/// `hasImportedConfig` and `peersFound` are separate inputs because the caller decides
/// what counts: the Mac reads its dialed-in roster for peers and its library for
/// configurations. `noAgent` is never returned here, because an absent agent produces
/// no snapshot at all and only a client can observe that.
public func macRelaySituation(
  snapshot: TunnelDaemonStatusSnapshot,
  hasImportedConfig: Bool,
  peersFound: Bool
) -> RelaySituation {
  if let lastError = snapshot.lastError, !lastError.isEmpty {
    return .failed
  }
  if !hasImportedConfig {
    return .noConfigImported
  }
  if snapshot.vpnProfileState == .disabled {
    return .vpnProfileDisabled
  }
  guard snapshot.connectedPeerName != nil else {
    if !peersFound, snapshot.advertising == .notAdvertising {
      return .notDiscoverable
    }
    return peersFound ? .noPeerSelected : .noPeersFound
  }
  if snapshot.activeConfigID == nil {
    return .noActiveConfig
  }
  return routingSituation(snapshot: snapshot)
}

// MARK: - iPhone

/// The iPhone's situation, decided the same way from the facts the iPhone has. It
/// installs no agent and holds no configuration library, so it names its saved tunnel
/// directly and reaches neither Mac-only situation.
public func phoneRelaySituation(
  snapshot: TunnelDaemonStatusSnapshot,
  peersFound: Bool
) -> RelaySituation {
  if let lastError = snapshot.lastError, !lastError.isEmpty {
    return .failed
  }
  if snapshot.peerState == .notSelected {
    return .notProvisioned
  }
  guard snapshot.connectedPeerName != nil else {
    return peersFound ? .noPeerSelected : .noPeersFound
  }
  return routingSituation(snapshot: snapshot)
}

// MARK: - Shared tail

// The connected tail is identical on both sides, and the connecting word used to be
// applied by the screen on top of the finished state, which is how the status word came
// to be derived in two places. It belongs to the situation. A producer that predates
// the phase falls back to whether the routes are installed, which is what the screens
// used to read.
private func routingSituation(snapshot: TunnelDaemonStatusSnapshot) -> RelaySituation {
  switch snapshot.routingPhase {
  case .connecting:
    return .connecting
  case .routing:
    return .routing
  case .idle, .stopping:
    return .readyToRoute
  case .none:
    return snapshot.routeState == .installed ? .routing : .readyToRoute
  }
}

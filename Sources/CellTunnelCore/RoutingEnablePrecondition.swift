//
//  RoutingEnablePrecondition.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-28.
//  Copyright © 2026, all rights reserved.
//

// MARK: - RoutingEnablePrecondition

/// The shared decision for whether the agent may turn routing on. Both the agent's
/// `enableRouting` (the live switch path) and `handleSetRoutingEnabled` (the request
/// path) consult `routingEnablePrecondition` so the no-active-config rejection, its
/// error code, and its message stay identical across the two entry points, and so the
/// relay-hosted fast path is the only branch allowed to proceed without a resolvable
/// config.
public enum RoutingEnablePrecondition: Equatable, Sendable {
  /// A resolvable active config exists, so routing can start the relay session.
  case activeConfigReady
  /// No resolvable active config, so routing must reject, set the error, and not start.
  case noActiveConfig
  /// The relay is already hosted, so routing reconciles routes without needing a config.
  case relayHostedReady

  /// The error code a rejection returns, or `nil` when routing may proceed. Keeps the
  /// request path's failure code tied to the same decision the live path records as
  /// `lastStartError`.
  public var rejectionErrorCode: TunnelControlErrorCode? {
    switch self {
    case .relayHostedReady, .activeConfigReady:
      return nil
    case .noActiveConfig:
      return .configSelectionRequired
    }
  }

  /// Whether routing may proceed past the precondition to mark intent and start.
  public var canProceed: Bool {
    rejectionErrorCode == nil
  }
}

// MARK: - Shared message

/// The user-facing message for a no-active-config rejection, shared by the snapshot
/// `lastError` the live path sets and the failure response the request path returns, so
/// the two cannot drift.
public let noActiveConfigSelectedMessage = "no active config selected"

// MARK: - Decision

/// Classifies whether routing may turn on. A hosted relay short-circuits because it
/// needs no config to reconcile its routes; otherwise a resolvable active config is
/// required. The caller resolves the config synchronously and passes whether it
/// resolved, so this stays a pure function with no store access.
public func routingEnablePrecondition(
  relayHosted: Bool,
  hasResolvableActiveConfig: Bool
) -> RoutingEnablePrecondition {
  if relayHosted {
    return .relayHostedReady
  }
  if hasResolvableActiveConfig {
    return .activeConfigReady
  }
  return .noActiveConfig
}

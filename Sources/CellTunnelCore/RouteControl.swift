//
//  RouteControl.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-27.
//  Copyright © 2026, all rights reserved.
//

// MARK: - RouteControlPresentation

/// How the single Route traffic switch presents itself, the one value the status
/// screens read to decide whether the switch shows and whether it is live. `hidden`
/// when no peer can carry traffic, `disabled` when a peer is connected but no config
/// is active and the hint names the missing choice, `enabled` when the switch is a
/// live control.
public enum RouteControlPresentation: Equatable, Sendable {
  case disabled(hint: String)
  case enabled
  case hidden
}

// MARK: - RouteControl

/// The derived state of the single Route traffic switch, computed once from the live
/// relay signals so the iPhone and the Mac render the switch the same way and the
/// rule is unit tested in one place. `presentation` decides visibility and whether
/// the switch is usable, `isOn` is the displayed switch value, and `isConnecting` is
/// true while a turn-on request waits for the relay to come up, so the screen shows a
/// spinner and the `Connecting` status word.
public struct RouteControl: Equatable, Sendable {
  public let presentation: RouteControlPresentation
  public let isOn: Bool
  public let isConnecting: Bool

  /// The hint shown on the disabled switch when a peer is connected but no config is
  /// active, naming the choice the user must make before routing can start.
  public static let chooseConfigHint = "Choose a config"

  /// Derives the switch state from the agent's routing intent, the shared value both
  /// the iPhone and the Mac mirror, so the switch reads the same on each rather than
  /// from a local running flag that is always set on the iPhone. The switch reads on
  /// only when it is the enabled control and a turn-on request is pending or the routing
  /// intent is engaged, so it stays on through a brief link drop while the intent holds,
  /// reads off in the ready-to-route state, and never reads on while hidden or disabled.
  /// `isConnecting`
  /// is true whenever the switch is engaged but routes are not installed yet, which
  /// covers both the first connect and a mid-session reconnect. Pure: the same inputs
  /// always produce the same value.
  public init(
    isPeerConnected: Bool,
    isRoutingEngaged: Bool,
    hasActiveConfig: Bool,
    isRouting: Bool,
    requestedRouting: Bool,
    isRequestPending: Bool
  ) {
    let resolvedPresentation: RouteControlPresentation
    if !isPeerConnected {
      resolvedPresentation = .hidden
    } else if !hasActiveConfig {
      resolvedPresentation = .disabled(hint: Self.chooseConfigHint)
    } else {
      resolvedPresentation = .enabled
    }
    presentation = resolvedPresentation

    let isEngaged: Bool
    if isRequestPending {
      isEngaged = requestedRouting
    } else {
      isEngaged = isRoutingEngaged
    }
    // The switch reads on only when it is the enabled control, so a hidden (no peer) or
    // disabled (no active config) switch never shows on even if a stale pending request
    // or a lingering engaged flag is still set.
    isOn = resolvedPresentation == .enabled && isEngaged
    isConnecting = resolvedPresentation == .enabled && isEngaged && !isRouting
  }
}

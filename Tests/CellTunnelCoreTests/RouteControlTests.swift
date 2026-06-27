//
//  RouteControlTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - RouteControlTests

/// Covers the observable states of the single Route traffic switch plus the link-drop
/// case, the rule the iPhone and the Mac both render the switch from. The engaged
/// signal is the agent's routing intent, the shared value both sides mirror, never a
/// local running flag.
struct RouteControlTests {
  // MARK: - Hidden

  @Test func hiddenWhenNoPeer() {
    let control = RouteControl(
      isPeerConnected: false,
      isRoutingEngaged: false,
      hasActiveConfig: false,
      isRouting: false,
      requestedRouting: false,
      isRequestPending: false
    )

    #expect(control.presentation == .hidden)
    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }

  // MARK: - Disabled

  @Test func disabledWhenPeerButNoConfig() {
    let control = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: false,
      hasActiveConfig: false,
      isRouting: false,
      requestedRouting: false,
      isRequestPending: false
    )

    #expect(control.presentation == .disabled(hint: RouteControl.chooseConfigHint))
    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }

  // MARK: - Ready to route

  @Test func readyToRouteWhenPeerAndConfigButIntentOff() {
    // The peer is connected and a config is active, but the agent's routing intent is
    // off, so the switch reads off. The intent is the only engaged signal, never a
    // local running flag, so the iPhone, whose runtime is always running, reads off
    // here exactly as the Mac does.
    let control = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: false,
      hasActiveConfig: true,
      isRouting: false,
      requestedRouting: false,
      isRequestPending: false
    )

    #expect(control.presentation == .enabled)
    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }

  // MARK: - Connecting

  @Test func connectingWhileTurnOnPending() {
    let control = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: false,
      hasActiveConfig: true,
      isRouting: false,
      requestedRouting: true,
      isRequestPending: true
    )

    #expect(control.presentation == .enabled)
    #expect(control.isOn == true)
    #expect(control.isConnecting == true)
  }

  // MARK: - Routing

  @Test func routingWhenIntentOnAndRoutesInstalled() {
    let control = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: true,
      hasActiveConfig: true,
      isRouting: true,
      requestedRouting: false,
      isRequestPending: false
    )

    #expect(control.presentation == .enabled)
    #expect(control.isOn == true)
    #expect(control.isConnecting == false)
  }

  // MARK: - Link drop stays on

  @Test func staysOnWhenLinkBrieflyDropsAfterConnect() {
    // Intent on and routes installed: the switch is on and not connecting.
    let routing = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: true,
      hasActiveConfig: true,
      isRouting: true,
      requestedRouting: false,
      isRequestPending: false
    )

    #expect(routing.isOn == true)
    #expect(routing.isConnecting == false)

    // A real mid-session link drop has no pending request: the agent's routing intent
    // is still on but the routes are withdrawn. The switch stays on and reads as
    // connecting, never off, so the user does not have to touch it.
    let reconnecting = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: true,
      hasActiveConfig: true,
      isRouting: false,
      requestedRouting: false,
      isRequestPending: false
    )

    #expect(reconnecting.isOn == true)
    #expect(reconnecting.isConnecting == true)
  }

  // MARK: - Turn off

  @Test func offWhileTurnOffPending() {
    // Turning off while the intent is briefly still on reads off, not on, so the switch
    // follows the user's request as the session tears down.
    let control = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: true,
      hasActiveConfig: true,
      isRouting: true,
      requestedRouting: false,
      isRequestPending: true
    )

    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }

  // MARK: - Engaged but not the enabled control

  @Test func offWhenDisabledEvenIfEngaged() {
    // The active config was cleared while routing was engaged: the switch is disabled
    // (no config), so it must read off rather than show on beside the choose-a-config
    // hint.
    let control = RouteControl(
      isPeerConnected: true,
      isRoutingEngaged: true,
      hasActiveConfig: false,
      isRouting: true,
      requestedRouting: false,
      isRequestPending: false
    )

    #expect(control.presentation == .disabled(hint: RouteControl.chooseConfigHint))
    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }

  @Test func offWhenHiddenEvenIfRequestPending() {
    // No peer can carry traffic, so the switch is hidden; a stale pending turn-on request
    // must not make it read on.
    let control = RouteControl(
      isPeerConnected: false,
      isRoutingEngaged: false,
      hasActiveConfig: true,
      isRouting: false,
      requestedRouting: true,
      isRequestPending: true
    )

    #expect(control.presentation == .hidden)
    #expect(control.isOn == false)
    #expect(control.isConnecting == false)
  }
}

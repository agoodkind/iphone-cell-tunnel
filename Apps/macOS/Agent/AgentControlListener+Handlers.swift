//
//  AgentControlListener+Handlers.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - Handler registration

/// The callbacks the controller registers before the listener starts, so what the
/// iPhone reports over the control link reaches the controller's state.
extension AgentControlListener {
  /// Registers the routing-choice handler before the listener starts.
  func setRoutingHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
    onSetRoutingEnabled = handler
  }

  /// Registers the peer-public-address handler before the listener starts.
  func setPeerPublicAddressHandler(_ handler: @escaping @Sendable (AddressPair) -> Void) {
    onPeerPublicAddress = handler
  }

  /// Registers the peer-device-name handler before the listener starts.
  func setPeerDeviceNameHandler(_ handler: @escaping @Sendable (String) -> Void) {
    onPeerDeviceName = handler
  }

  /// Registers the peer link-inventory handler before the listener starts.
  func setPeerAvailableLinksHandler(
    _ handler: @escaping @Sendable ([RelayLinkSummary]) -> Void
  ) {
    onPeerAvailableLinks = handler
  }

  /// Registers the selected-connection-dropped handler before the listener starts.
  func setConnectionDroppedHandler(_ handler: @escaping @Sendable () -> Void) {
    onConnectionDropped = handler
  }

  /// Registers the session-established handler before the listener starts, fired with
  /// the selected peer's id on each selection.
  func setSessionEstablishedHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
    onSessionEstablished = handler
  }

  /// Registers the roster-changed handler before the listener starts, fired with the
  /// full set of connected iPhones whenever it changes.
  func setRosterChangedHandler(_ handler: @escaping @Sendable ([ConnectedPeer]) -> Void) {
    onRosterChanged = handler
  }

  /// Registers the serving-changed handler before the listener starts, fired with true
  /// once the socket binds and false once it fails.
  ///
  /// Binding the fixed control port happens after `start()` returns, so a failure never
  /// reaches the caller as a thrown error. Without this the controller holds a listener
  /// that publishes nothing, and its own start path returns early because a listener
  /// object exists, so the Mac stays undiscoverable with no error a person can act on.
  func setServingChangedHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
    onServingChanged = handler
  }
}

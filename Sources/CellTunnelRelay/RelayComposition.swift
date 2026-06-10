//
//  RelayComposition.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - RelayControlChannel

/// The control link to the Mac agent. It dials the agent, receives the WireGuard
/// server endpoint, reports a dropped connection, and answers status pushes.
/// `RelayRuntime` reaches it through this protocol so a test can drive the engine
/// with a fake channel. The handlers are passed to `configure` rather than set as
/// properties, so the protocol need not be class-bound.
@MainActor
protocol RelayControlChannel: Sendable {
  func configure(
    onSetServerEndpoint: @escaping @MainActor (RelayEndpoint) -> Void,
    onConnectionDropped: @escaping @MainActor () -> Void,
    onRouteState: @escaping @MainActor (Bool) -> Void,
    onPeerName: @escaping @MainActor (String?) -> Void,
    statusProvider: @escaping @MainActor () -> RelayControlMessage.Status
  )
  /// Reports the agent's persisted routing intent, the value behind the Route
  /// traffic switch, pushed on every change and on each connection handshake.
  func setRoutingIntentHandler(_ handler: @escaping @MainActor (Bool) -> Void)
  func setPeerPublicAddressHandler(_ handler: @escaping @MainActor (AddressPair) -> Void)
  func setConnectionReadyHandler(_ handler: @escaping @MainActor () -> Void)
  /// Reports the Mac agent control services the browser currently sees, each a
  /// selectable peer. The engine stores them for the served snapshot and decides
  /// which one to dial.
  func setServicesChangedHandler(
    _ handler: @escaping @MainActor ([TunnelRelayService]) -> Void
  )
  func start()
  func stop()
  func sendRoutingEnabled(_ enabled: Bool)
  func sendPublicAddress(_ addresses: AddressPair)
  /// Dials the discovered service with the given id, dropping any existing
  /// connection to a different peer, so selection drives which Mac the iPhone joins.
  func selectService(id: String)
}

// MARK: - PhoneControlClient

extension PhoneControlClient: RelayControlChannel {
  func configure(
    onSetServerEndpoint: @escaping @MainActor (RelayEndpoint) -> Void,
    onConnectionDropped: @escaping @MainActor () -> Void,
    onRouteState: @escaping @MainActor (Bool) -> Void,
    onPeerName: @escaping @MainActor (String?) -> Void,
    statusProvider: @escaping @MainActor () -> RelayControlMessage.Status
  ) {
    self.onSetServerEndpoint = onSetServerEndpoint
    self.onConnectionDropped = onConnectionDropped
    self.onRouteState = onRouteState
    self.onPeerName = onPeerName
    self.statusProvider = statusProvider
  }

  func setRoutingIntentHandler(_ handler: @escaping @MainActor (Bool) -> Void) {
    onRoutingIntent = handler
  }

  func setPeerPublicAddressHandler(_ handler: @escaping @MainActor (AddressPair) -> Void) {
    onPeerPublicAddress = handler
  }

  func setConnectionReadyHandler(_ handler: @escaping @MainActor () -> Void) {
    onConnectionReady = handler
  }

  func setServicesChangedHandler(
    _ handler: @escaping @MainActor ([TunnelRelayService]) -> Void
  ) {
    onServicesChanged = handler
  }
}

// MARK: - RelayDiscovering

/// The discovery probe that reports which interfaces the Mac agent is reachable
/// on. `RelayRuntime` feeds its results to the forwarder through this protocol.
protocol RelayDiscovering: Sendable {
  func configure(onDiscover: @escaping @Sendable ([RelayMacInterface]) -> Void)
  func start()
  func stop()
}

// MARK: - RelayPathProbe

extension RelayPathProbe: RelayDiscovering {
  func configure(onDiscover: @escaping @Sendable ([RelayMacInterface]) -> Void) {
    self.onDiscover = onDiscover
  }
}

// MARK: - CellularPathObserving

/// The cellular path observer that holds the latest cellular `NWPath` snapshot
/// for status reporting. `RelayRuntime` reads its snapshot through this protocol.
protocol CellularPathObserving: Sendable {
  var snapshot: CellularPathSnapshot { get }

  func setPathChangeHandler(_ handler: @escaping @Sendable () -> Void)
  func start()
  func stop()
}

// MARK: - CellularPathObserver

extension CellularPathObserver: CellularPathObserving {}

// MARK: - RelayComposition

/// The bundle of relay collaborators a host hands to the engine. Each host builds
/// the one preset that matches where it runs, so the engine owns no concrete
/// collaborator and reads no build target.
public struct RelayComposition {
  let binder: RelayInterfaceBinder
  let control: RelayControlChannel
  let probe: RelayDiscovering
  let cellular: CellularPathObserving
  let publicProbe: PublicAddressProbe
  let configuration: RelayConfiguration
  /// This device's name, the host's `UIDevice.current.name`, carried in the status
  /// push so the agent reports it as the connected peer. The relay framework stays
  /// UIKit-free, so the host supplies the value.
  let deviceName: String?

  /// The on-device graph: pin each connection to its physical interface. The egress
  /// interface type comes from `configuration`, the source of truth, not a literal.
  public static func pinned(
    deviceName: String? = nil,
    configuration: RelayConfiguration = .default
  ) -> RelayComposition {
    logger.notice("relay composition built mode=\("pinned", privacy: .public)")
    return RelayComposition(
      binder: PinnedInterfaceBinder(egressInterfaceType: configuration.egressInterfaceType),
      control: PhoneControlClient(),
      probe: RelayPathProbe(),
      cellular: CellularPathObserver(
        requiredInterfaceType: configuration.egressInterfaceType),
      publicProbe: PublicAddressProbe(),
      configuration: configuration,
      deviceName: deviceName
    )
  }

  /// The in-process simulator graph: reach every peer over the host network. There
  /// is no cellular radio, so the egress is unpinned; the carrying-link preference
  /// still comes from `configuration`.
  public static func hostNetwork(
    deviceName: String? = nil,
    configuration: RelayConfiguration = .default
  ) -> RelayComposition {
    logger.notice("relay composition built mode=\("host-network", privacy: .public)")
    return RelayComposition(
      binder: HostNetworkInterfaceBinder(),
      control: PhoneControlClient(),
      probe: RelayPathProbe(),
      cellular: CellularPathObserver(requiredInterfaceType: nil),
      publicProbe: PublicAddressProbe(),
      configuration: configuration,
      deviceName: deviceName
    )
  }
}

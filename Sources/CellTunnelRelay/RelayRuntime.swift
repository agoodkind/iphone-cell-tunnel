//
//  RelayRuntime.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let publicAddressRefreshIntervalSeconds = 60

// The relay protocol name surfaced on the status `Protocol` row. The iPhone relay
// carries WireGuard datagrams for the Mac, so it is one of the few producers that
// names the protocol on the served snapshot.
private let relayProtocolName = "WireGuard"

// MARK: - RelayStatusState

/// The latest relay observations the forwarder and the control client push
/// through their callbacks, held behind a `Mutex` so the status path can read
/// them from any thread without hopping to the MainActor.
private struct RelayStatusState {
  var running = false
  var lastError: String?
  /// The peer device name shown as `Connected to`, the name of the agent's
  /// control service the phone connected to. It is reported only while a live
  /// data peer is up, so the screen shows it in the connected states.
  var connectedPeerName: String?
  /// The agent's control-service name (the Mac hostname), captured when the
  /// control link connects, and shown as the displayed peer name.
  var controlPeerName: String?
  /// Whether the data plane has a live peer link, from the forwarder.
  var hasLivePeer = false
  var relayState = WireGuardDatagramRelayState.stopped.displayName
  /// Whether the agent has confirmed the program routes are installed. The agent
  /// owns the routes and reports this over the control link, so it is the truth
  /// the route state reports, not the local routing intent.
  var routeInstalled = false
  /// The agent's persisted routing intent, mirrored over the control link. The
  /// Route traffic switch shows this; `nil` until the agent's first push, so an
  /// old agent that never sends it leaves the switch on the route-state fallback.
  var routingIntent: TunnelRoutingIntent?
  /// The WireGuard server endpoint the agent sent over the control link. The host
  /// is shown as the relay host; the resolved addresses are the server's IPs.
  var serverEndpoint: RelayEndpoint?
  /// The server endpoint hostname resolved to its A and AAAA records, shown as the
  /// relay server IPv4 and IPv6.
  var relayResolved: HostAddressResolver.Resolved?
  /// The carrying link's interface, transport class, and addresses, reported on the
  /// `Connection` section.
  var localLinkInterfaceName: String?
  var localLinkClass: RelayLinkClass?
  var localLinkAddresses: AddressPair?
  var peerLinkAddresses: AddressPair?
  /// This side's relay-link candidates from the forwarder, shown on the
  /// local `Available Interfaces` row and carried in each status push.
  var localAvailableLinks: [RelayLinkSummary] = []
  /// The candidates the Mac reports about itself over the control link, or
  /// `nil` before the agent reports them.
  var peerAvailableLinks: [RelayLinkSummary]?
  /// The Mac agent control services the iPhone has discovered over the local link,
  /// each a selectable peer, surfaced in the served snapshot's `discovery.services`.
  var discoveredServices: [TunnelRelayService] = []
  /// The id of the discovered service the user selected to dial, surfaced as the
  /// served snapshot's `discovery.selectedServiceID`.
  var selectedServiceID: String?
}

// MARK: - RelayRuntime

/// The iPhone relay engine, independent of its host. It owns the data plane
/// forwarder, the control link to the agent, the discovery probe, the cellular
/// path observer, and the status snapshot the UI reads. Two hosts drive the same
/// engine: the Network Extension packet tunnel hosts it on device to keep it
/// alive in the background, and the app hosts it in-process in the simulator,
/// where the Network Extension has no launchable `nehelper`. The host owns the
/// tun and the lifecycle callbacks; this owns the relay.
///
/// `@unchecked Sendable`: each stored member confines its own state to its queue
/// or behind the `Mutex`, and the `@MainActor` control client is reached only
/// through `Task { @MainActor }`.
public final class RelayRuntime: @unchecked Sendable {
  private let forwarder: PhoneRelayForwarder
  private let control: RelayControlChannel
  private let cellular: CellularPathObserving
  private let probe: RelayDiscovering
  private let publicProbe: PublicAddressProbe
  private var publicExchange: PublicAddressExchange?
  private var publicRefreshTimer: DispatchSourceTimer?
  private let preferredCarryingInterface: String?
  /// This device's name, supplied by the host, sent in each status push so the
  /// agent reports it as the connected peer.
  private let deviceName: String?
  private let statusState = Mutex(RelayStatusState())

  public init(composition: RelayComposition) {
    forwarder = PhoneRelayForwarder(interfaceBinder: composition.binder)
    control = composition.control
    cellular = composition.cellular
    probe = composition.probe
    publicProbe = composition.publicProbe
    preferredCarryingInterface = composition.configuration.preferredCarryingInterface
    deviceName = composition.deviceName
  }

  // MARK: - Lifecycle

  /// Brings up the relay: the cellular path observer, the forwarder and its
  /// status callbacks, the discovery probe that feeds the forwarder, and the
  /// control client that dials the agent for the WireGuard server endpoint.
  public func start() {
    buildPublicExchange()
    cellular.setPathChangeHandler { [weak self] in
      self?.refreshDevicePublicAddress()
    }
    cellular.start()
    configureForwarderCallbacks()
    forwarder.start()
    forwarder.applyPreferredInterface(preferredCarryingInterface)
    configureTransportSelection()
    startControlClient()
    startPublicRefreshTimer()
    statusState.withLock { $0.running = true }
    logger.notice("relay runtime started")
  }

  // Builds the public-address exchange: a probe-and-hold value with no connection
  // state. The runtime probes this device and sends the result over the control
  // link on each trigger, and stores the peer's address received over that link.
  private func buildPublicExchange() {
    publicExchange = PublicAddressExchange(probe: publicProbe)
  }

  // Probes this device's public address and sends it to the agent over the control
  // link. Driven by the control connection becoming ready, an egress path change,
  // and the periodic backstop, so the address stays current as the network moves.
  private func refreshDevicePublicAddress() {
    guard let exchange = publicExchange else {
      return
    }
    let channel = control
    Task {
      let device = await exchange.probeDevice()
      await MainActor.run { channel.sendPublicAddress(device) }
    }
  }

  // A repeating dispatch timer re-probes the public address on a slow backstop, so
  // a missed path event cannot leave the displayed address stale. Off the main
  // thread, so the handler is `@Sendable` and hops as needed.
  private func startPublicRefreshTimer() {
    publicRefreshTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + .seconds(publicAddressRefreshIntervalSeconds),
      repeating: .seconds(publicAddressRefreshIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      self?.refreshDevicePublicAddress()
    }
    timer.resume()
    publicRefreshTimer = timer
    logger.notice(
      """
      public address refresh timer started \
      intervalSeconds=\(publicAddressRefreshIntervalSeconds, privacy: .public)
      """
    )
  }

  private func stopPublicRefreshTimer() {
    publicRefreshTimer?.cancel()
    publicRefreshTimer = nil
  }

  /// Tears the relay down and resets the status to stopped.
  public func stop() {
    let client = self.control
    Task { @MainActor in client.stop() }
    stopPublicRefreshTimer()
    probe.stop()
    forwarder.stop()
    cellular.stop()
    publicExchange = nil
    statusState.withLock { state in
      state.running = false
      state.connectedPeerName = nil
      state.relayState = WireGuardDatagramRelayState.stopped.displayName
      state.routeInstalled = false
      state.localLinkInterfaceName = nil
      state.localLinkClass = nil
      state.localLinkAddresses = nil
      state.peerLinkAddresses = nil
      state.localAvailableLinks = []
      state.peerAvailableLinks = nil
    }
    logger.notice("relay runtime torn down")
  }

  // MARK: - Control

  /// Pushes the routing choice to the agent over the control link, which installs
  /// or withdraws the program routes. The reported route state is not set here; it
  /// follows the agent's confirmation over the control link, so the UI never shows
  /// routing the agent has not installed. Off is passthrough, on is routing.
  public func setRoutingEnabled(_ enabled: Bool) {
    let client = control
    Task { @MainActor in client.sendRoutingEnabled(enabled) }
    logger.notice("relay runtime routing requested enabled=\(enabled, privacy: .public)")
  }

  // MARK: - Status

  /// One status reading assembled from the live relay observations, the cellular
  /// path, and the forwarder metrics.
  public func statusSnapshot() -> TunnelDaemonStatusSnapshot {
    let state = statusState.withLock { $0 }
    let publicAddresses = publicExchange?.resolved ?? PublicAddressExchange.Resolved()
    return TunnelDaemonStatusSnapshot(
      running: state.running,
      routeState: state.routeInstalled ? .installed : .notInstalled,
      peerState: state.running ? .relaySelected : .notSelected,
      lastError: state.lastError,
      discovery: discoverySnapshot(from: state),
      phoneCounters: forwarder.metrics.snapshot(),
      cellularPath: cellular.snapshot,
      connectedPeerName: state.connectedPeerName,
      relayState: state.relayState,
      localLinkInterfaceName: state.localLinkInterfaceName,
      localLinkClass: state.localLinkClass,
      devicePublicAddresses: publicAddresses.device,
      peerPublicAddresses: publicAddresses.peer,
      localLinkAddresses: state.localLinkAddresses,
      peerLinkAddresses: state.peerLinkAddresses,
      localAvailableLinks: state.localAvailableLinks,
      peerAvailableLinks: state.peerAvailableLinks,
      relayHost: state.serverEndpoint?.host,
      relayServerIPv4Address: state.relayResolved?.ipv4,
      relayServerIPv6Address: state.relayResolved?.ipv6,
      relayProtocol: relayProtocolName,
      routingIntentEnabled: state.routingIntent
    )
  }

  // Builds the discovery section the same way the agent does: the discovered Mac
  // control services as selectable peers, the current selection, and a phase that
  // reads ready once any peer is visible.
  private func discoverySnapshot(from state: RelayStatusState) -> TunnelDiscoverySnapshot {
    TunnelDiscoverySnapshot(
      phase: state.discoveredServices.isEmpty ? .browsing : .ready,
      services: state.discoveredServices,
      selectedServiceID: state.selectedServiceID
    )
  }

  // MARK: - Peer selection

  /// Records the user's chosen Mac control service and drives the control client to
  /// dial it, so the iPhone connects to the selected peer rather than the first one
  /// the browser reports.
  public func selectPeer(id: String) {
    statusState.withLock { $0.selectedServiceID = id }
    let client = control
    Task { @MainActor in client.selectService(id: id) }
    logger.notice("relay runtime selected peer id=\(id, privacy: .public)")
  }

  // Builds one status push from the live cellular path, the forwarder metrics, the
  // last error, and the host-supplied device name, which the iPhone sends to the
  // agent so the agent reports this device as the connected peer.
  private func currentStatusPush(deviceName: String?) -> RelayControlMessage.Status {
    let cellularPath = cellular.snapshot
    let relayStatus = statusState.withLock { state in
      (lastError: state.lastError, availableLinks: state.localAvailableLinks)
    }
    return RelayControlMessage.Status(
      hasCellularPath: cellularPath.isSatisfied,
      cellularInterface: cellularPath.interfaceName,
      lastError: relayStatus.lastError,
      counters: forwarder.metrics.snapshot(),
      deviceName: deviceName,
      availableLinks: relayStatus.availableLinks
    )
  }

  /// Builds a minimal status push for the narrow nil-self fallback path.
  private static func emptyStatusPush(deviceName: String?) -> RelayControlMessage.Status {
    RelayControlMessage.Status(
      hasCellularPath: false,
      deviceName: deviceName,
      availableLinks: []
    )
  }

  // MARK: - Wiring

  private func configureForwarderCallbacks() {
    forwarder.onStateChange = { [weak self] state in
      self?.statusState.withLock { $0.relayState = state.displayName }
      logger.notice("phone relay state changed state=\(state.rawValue, privacy: .public)")
    }
    forwarder.onError = { [weak self] message in
      self?.statusState.withLock { $0.lastError = message }
      logger.error("phone relay reported error=\(message, privacy: .public)")
    }
    forwarder.onPeerChange = { [weak self] live in
      self?.statusState.withLock { state in
        state.hasLivePeer = live
        state.connectedPeerName = live ? state.controlPeerName : nil
      }
      logger.notice("phone relay live peer changed live=\(live, privacy: .public)")
    }
    forwarder.onEgressInterfaceChange = { [weak self] name, linkClass, local, peer in
      self?.statusState.withLock { state in
        state.localLinkInterfaceName = name
        state.localLinkClass = linkClass
        state.localLinkAddresses = local
        state.peerLinkAddresses = peer
      }
      logger.notice(
        """
        phone relay carrying link interface=\(name ?? "none", privacy: .public) \
        class=\(linkClass?.rawValue ?? "none", privacy: .public)
        """
      )
    }
    forwarder.onAvailableLinksChange = { [weak self] links in
      self?.statusState.withLock { $0.localAvailableLinks = links }
    }
  }

  private func configureTransportSelection() {
    let relayForwarder = self.forwarder
    probe.configure { interfaces in
      relayForwarder.reconcileLinks(interfaces)
    }
    probe.start()
  }

  // The status closure borrows the non-copyable `statusState` Mutex through a
  // weak self instead of a hoisted local.
  private func startControlClient() {
    let client = self.control
    let relayForwarder = self.forwarder
    let hostDeviceName = self.deviceName
    Task { @MainActor [weak self] in
      client.configure(
        onSetServerEndpoint: { [weak self] endpoint in
          relayForwarder.setServerEndpoint(endpoint)
          self?.statusState.withLock { $0.serverEndpoint = endpoint }
          self?.resolveRelayServer(host: endpoint.host)
        },
        onConnectionDropped: { [weak self] in
          relayForwarder.resetLinks()
          // The control link dropped, so any installed routes no longer
          // hold and the peer is gone; clear the route, the peer name, and
          // the peer's public address until the agent reconnects.
          self?.publicExchange?.clearPeer()
          self?.statusState.withLock { state in
            state.routeInstalled = false
            state.controlPeerName = nil
            state.connectedPeerName = nil
            state.peerAvailableLinks = nil
          }
        },
        onRouteState: { [weak self] installed in
          self?.statusState.withLock { $0.routeInstalled = installed }
        },
        onPeerName: { [weak self] name in
          self?.statusState.withLock { state in
            state.controlPeerName = name
            if state.hasLivePeer {
              state.connectedPeerName = name
            }
          }
          logger.notice(
            "relay peer name resolved peer=\(name ?? "none", privacy: .public)"
          )
        },
        statusProvider: { [weak self, hostDeviceName] in
          self?.currentStatusPush(deviceName: hostDeviceName)
            ?? Self.emptyStatusPush(deviceName: hostDeviceName)
        }
      )
      self?.registerControlHandlers(on: client)
      client.start()
    }
  }

  // Registers the secondary control handlers: the peer's public address, the
  // peer's link inventory, the connection-ready refresh, the mirrored routing
  // intent, and the discovered-services feed.
  @MainActor
  private func registerControlHandlers(on client: any RelayControlChannel) {
    client.setPeerPublicAddressHandler { [weak self] addresses in
      self?.publicExchange?.received(addresses)
    }
    client.setPeerAvailableLinksHandler { [weak self] links in
      self?.statusState.withLock { $0.peerAvailableLinks = links }
    }
    client.setConnectionReadyHandler { [weak self] in
      self?.refreshDevicePublicAddress()
    }
    client.setRoutingIntentHandler { [weak self] enabled in
      self?.statusState.withLock { $0.routingIntent = TunnelRoutingIntent(enabled: enabled) }
    }
    client.setServicesChangedHandler { [weak self] services in
      self?.applyDiscoveredServices(services)
    }
  }

  // Stores the discovered Mac control services for the snapshot and resolves which
  // one to dial: the standing selection when still present, otherwise the lone peer
  // auto-selected. With several peers and no selection nothing dials until the user
  // picks one. The dial itself runs on the control client's MainActor.
  private func applyDiscoveredServices(_ services: [TunnelRelayService]) {
    let target: String? = statusState.withLock { state in
      state.discoveredServices = services
      let resolved = Self.dialTarget(selected: state.selectedServiceID, services: services)
      state.selectedServiceID = resolved ?? state.selectedServiceID
      return resolved
    }
    guard let target else {
      return
    }
    let client = control
    Task { @MainActor in client.selectService(id: target) }
  }

  // Resolves which discovered service to dial: the standing selection when it is
  // still present, otherwise the lone discovered peer, otherwise none.
  private static func dialTarget(
    selected: String?,
    services: [TunnelRelayService]
  ) -> String? {
    if let selected, services.contains(where: { $0.id == selected }) {
      return selected
    }
    if services.count == 1 {
      return services.first?.id
    }
    return nil
  }

  // Resolves the WireGuard endpoint hostname to its A and AAAA records off the
  // MainActor and caches them, so the relay section shows the server's real
  // addresses rather than the hostname in a family row. An IP literal resolves to
  // itself.
  private func resolveRelayServer(host: String) {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let resolved = HostAddressResolver.resolve(host: host)
      self?.statusState.withLock { $0.relayResolved = resolved }
      logger.notice(
        """
        relay server resolved host=\(host, privacy: .public) \
        hasIPv4=\(resolved.ipv4 != nil, privacy: .public) \
        hasIPv6=\(resolved.ipv6 != nil, privacy: .public)
        """
      )
    }
  }
}

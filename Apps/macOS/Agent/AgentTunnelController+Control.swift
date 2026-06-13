//
//  AgentTunnelController+Control.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .daemon)
private let publicAddressRefreshIntervalSeconds = 60
/// Seconds to hold the program routes after the phone link drops before treating
/// the drop as real and withdrawing them, so a brief AWDL blip does not flip the
/// UI to passthrough. A drop that outlasts this withdraws as before.
private let routeWithdrawGraceSeconds = 3

// MARK: - Control link hosting

extension AgentTunnelController {
  /// The agent hosts the control link because a listener only receives inbound
  /// from the iPhone in a normal process, not inside a NetworkExtension. It
  /// parses the WireGuard server endpoint from the config and hands it to the
  /// listener, which sends it to the iPhone when the iPhone dials in.
  func startControlListener(wireGuardConfig: String) async throws {
    guard let endpoint = Self.serverEndpoint(fromConfig: wireGuardConfig) else {
      logger.error(
        """
        agent control listener start failed \
        reason=no-parseable-endpoint recovery=throw-missing-server-endpoint
        """
      )
      throw AgentTunnelControllerError.missingServerEndpoint
    }
    await controlListener?.stop()
    let listener = AgentControlListener(serverEndpoint: endpoint)

    // The public-address exchange holds this host's and the iPhone's measured
    // public addresses; the snapshot reads both so the Mac shows `Device / Public`
    // and `Peer / Public`. The controller probes this host on its triggers and
    // the listener sends the result; the listener stores the iPhone's address here.
    let exchange = PublicAddressExchange()
    publicExchange = exchange
    await configurePeerHandlers(on: listener, exchange: exchange)

    controlListener = listener
    try await listener.start()

    startEgressMonitor()
    startPublicRefreshTimer()
    // Warm the cached device address so the first connection carries it, and a
    // late-completing probe re-sends to whatever connection is then current.
    Task { await self.refreshDeviceAddress() }

    configureRelayBridgeHandlers()
    relayBridge.start(serviceName: stableHostName())
    onRelayActiveChange?(true)
    logger.notice(
      """
      agent control listener started host=\(endpoint.host, privacy: .public) \
      port=\(endpoint.port, privacy: .public)
      """
    )
  }

  /// Registers listener callbacks that surface peer control messages into
  /// controller state.
  private func configurePeerHandlers(
    on listener: AgentControlListener,
    exchange: PublicAddressExchange
  ) async {
    await listener.setRoutingHandler { [weak self] enabled in
      Task { await self?.setRoutingEnabled(enabled) }
    }
    await listener.setPeerPublicAddressHandler { addresses in
      exchange.received(addresses)
    }
    // The iPhone carries its device name in each status push; store it so the
    // snapshot reports it as `connectedPeerName`. The name follows the control
    // link: it is set from the push and cleared only when the control link drops,
    // so a brief data-link blip does not clear it.
    await listener.setPeerDeviceNameHandler { [weak self] name in
      self?.peerName.withLock { $0 = name }
    }
    await listener.setPeerAvailableLinksHandler { [weak self] links in
      self?.peerLinks.withLock { $0 = links }
    }
    // The selected control connection ending clears the connected peer name and the
    // bridge admit session, so the data plane goes idle until the Mac selects an
    // iPhone again. A non-selected peer ending does not fire this.
    await listener.setConnectionDroppedHandler { [weak self] in
      self?.peerName.withLock { $0 = nil }
      self?.peerLinks.withLock { $0 = nil }
      self?.relayBridge.clearSession()
    }
    // The roster of connected iPhones, surfaced into the snapshot so the Mac selector
    // lists them and flags the selected one.
    await listener.setRosterChangedHandler { [weak self] roster in
      self?.connectedPeers.withLock { $0 = roster }
    }
    // Selecting an iPhone installs its id as the bridge admit token, so the bridge
    // admits relay links only from the selected peer and drops links stamped with a
    // prior selection's id.
    await listener.setSessionEstablishedHandler { [weak self] sessionID in
      self?.relayBridge.updateSessionID(sessionID)
    }
    // Each accepted connection syncs the routing truth at handshake: the
    // persisted intent and the route state the agent currently derives from
    // intent and link, so a reconnect or app relaunch mirrors immediately.
    await listener.setRoutingSyncProvider { [weak self] in
      guard let self else {
        return (intent: true, installed: false)
      }
      let intent = await routingEnabled
      let linkUp = await phoneLinkUp
      return (intent: intent, installed: intent && linkUp)
    }
  }

  /// Registers relay bridge callbacks that surface local link state, the full
  /// adopted-link set, and the any-link-up transitions that reconcile routes.
  private func configureRelayBridgeHandlers() {
    relayBridge.onEgressInterfaceChange = { [weak self] name, linkClass, local, peer in
      self?.linkInfo.withLock { current in
        current = AgentLinkInfo(
          interfaceName: name,
          linkClass: linkClass,
          localAddresses: local,
          peerAddresses: peer
        )
      }
    }
    relayBridge.onAvailableLinksChange = { [weak self] links in
      self?.localLinks.withLock { $0 = links }
      Task { await self?.controlListener?.publishLinkInventory(links) }
    }
    relayBridge.onLinkSetChange = { [weak self] links in
      self?.agentLinks.withLock { $0 = links }
    }
    relayBridge.onPhoneConnected = { [weak self] in
      Task { await self?.handlePhoneLink(up: true) }
    }
    relayBridge.onPhoneDisconnected = { [weak self] in
      Task { await self?.handlePhoneLink(up: false) }
    }
  }

  func stopControlListener() async {
    await controlListener?.stop()
    controlListener = nil
    publicExchange = nil
    egressMonitor?.stop()
    egressMonitor = nil
    publicRefreshTimer?.cancel()
    publicRefreshTimer = nil
    routeWithdrawTimer?.cancel()
    routeWithdrawTimer = nil
    routeWithdrawGeneration += 1
    linkInfo.withLock { $0 = AgentLinkInfo() }
    localLinks.withLock { $0 = [] }
    peerLinks.withLock { $0 = nil }
    agentLinks.withLock { $0 = [] }
    peerName.withLock { $0 = nil }
    connectedPeers.withLock { $0 = [] }
    egressPath.withLock { $0 = EgressPath() }
    relayBridge.onEgressInterfaceChange = nil
    relayBridge.onAvailableLinksChange = nil
    relayBridge.onLinkSetChange = nil
    relayBridge.stop()
    onRelayActiveChange?(false)
    logger.notice("agent control link cleared on tunnel stop")
  }

  // MARK: - Public-address refresh

  /// Probes the Mac's public address and sends it to the iPhone over the control
  /// link. Driven by the listener starting, the Mac's egress path changing, a
  /// routing toggle, and a periodic backstop, so the served address stays current.
  func refreshDeviceAddress() async {
    guard let exchange = publicExchange else {
      return
    }
    let device = await exchange.probeDevice()
    await controlListener?.setDeviceAddress(device)
    await controlListener?.sendPublicAddressToCurrent(device)
    logger.notice("agent refreshed device public address")
  }

  // Watches the Mac's own default egress so a Wi-Fi switch or interface change
  // both stores the reading for the snapshot's `Device` rows and re-probes the
  // public address. The handler hops onto the actor for the re-probe.
  func startEgressMonitor() {
    let monitor = EgressPathMonitor(requiredInterfaceType: nil)
    monitor.onChange = { [weak self] path in
      self?.egressPath.withLock { $0 = path }
      Task { await self?.refreshDeviceAddress() }
    }
    monitor.start()
    egressMonitor = monitor
    logger.notice("agent egress monitor started")
  }

  // A repeating dispatch timer re-probes the public address on a slow backstop, so
  // a missed path event cannot leave the served address stale. The handler is
  // `@Sendable` and hops onto the actor.
  func startPublicRefreshTimer() {
    publicRefreshTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + .seconds(publicAddressRefreshIntervalSeconds),
      repeating: .seconds(publicAddressRefreshIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      Task { await self?.refreshDeviceAddress() }
    }
    timer.resume()
    publicRefreshTimer = timer
    logger.notice(
      """
      agent public address refresh timer started \
      intervalSeconds=\(publicAddressRefreshIntervalSeconds, privacy: .public)
      """
    )
  }

  /// Fills the served snapshot with the agent-side link and public-address fields,
  /// the same `Connection`, `Device / Public`, and `Peer / Public` rows the iPhone
  /// reports, which the Mac extension's snapshot does not carry.
  func augmented(_ status: TunnelDaemonStatusSnapshot) -> TunnelDaemonStatusSnapshot {
    var merged = status
    let link = linkInfo.withLock { $0 }
    merged.localLinkInterfaceName = link.interfaceName
    merged.localLinkClass = link.linkClass
    merged.localLinkAddresses = link.localAddresses
    merged.peerLinkAddresses = link.peerAddresses
    let publicAddresses = publicExchange?.resolved ?? PublicAddressExchange.Resolved()
    merged.devicePublicAddresses = publicAddresses.device
    merged.peerPublicAddresses = publicAddresses.peer
    merged.connectedPeerName = peerName.withLock { $0 }
    merged.localAvailableLinks = localLinks.withLock { $0 }
    merged.peerAvailableLinks = peerLinks.withLock { $0 }
    merged.cellularPath = CellularPathSnapshot(egress: egressPath.withLock { $0 })
    merged.routingIntentEnabled = TunnelRoutingIntent(enabled: routingEnabled)
    merged.agentLinks = agentLinks.withLock { $0 }
    merged.connectedPeers = connectedPeers.withLock { $0 }
    return merged
  }

  // MARK: - Routing control

  /// Records the user's routing choice, persists it, mirrors it to the phone, and
  /// reconciles routes against the live link. Routing on with a link up installs
  /// the program routes; routing off withdraws them. The intent persists through
  /// `RoutingIntentStore` and defaults to on, so a fresh start routes without a
  /// tap.
  func setRoutingEnabled(_ enabled: Bool) async {
    routingEnabled = enabled
    RoutingIntentStore.save(enabled)
    await controlListener?.sendRoutingIntent(enabled)
    logger.notice(
      "agent routing set enabled=\(enabled, privacy: .public) phoneLinkUp=\(self.phoneLinkUp, privacy: .public)"
    )
    if enabled, phoneLinkUp {
      await signalRouteState(true)
    } else if !enabled {
      await signalRouteState(false)
    }
  }

  /// Tracks the live phone link and reconciles routes. A link coming up installs
  /// routes only when routing is on; a link going down always withdraws them, so
  /// routing resumes by itself when the link returns while routing stays on.
  func handlePhoneLink(up: Bool) async {
    phoneLinkUp = up
    logger.notice("agent phone link changed up=\(up, privacy: .public)")
    // Every transition invalidates a pending debounced withdrawal and cancels its
    // timer, so a link that returns within the grace window keeps its routes.
    routeWithdrawGeneration += 1
    routeWithdrawTimer?.cancel()
    routeWithdrawTimer = nil
    if up {
      if routingEnabled {
        await signalRouteState(true)
      }
    } else {
      // Debounce the withdrawal so a sub-grace AWDL blip does not flip the UI to
      // passthrough. The peer name is not cleared here; it follows the control
      // link and clears only when that link drops.
      peerLinks.withLock { $0 = nil }
      scheduleRouteWithdraw(generation: routeWithdrawGeneration)
    }
  }

  // Schedules a one-shot timer that withdraws routes only if the link is still
  // down and no newer transition has happened when it fires.
  private func scheduleRouteWithdraw(generation: Int) {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + .seconds(routeWithdrawGraceSeconds))
    timer.setEventHandler { @Sendable [weak self] in
      Task { await self?.applyDebouncedWithdraw(generation: generation) }
    }
    timer.resume()
    routeWithdrawTimer = timer
  }

  private func applyDebouncedWithdraw(generation: Int) async {
    guard generation == routeWithdrawGeneration, !phoneLinkUp else {
      return
    }
    routeWithdrawTimer = nil
    await signalRouteState(false)
  }

  // MARK: - Config reading

  /// Reads the WireGuard config text at the given path, expanding a leading tilde,
  /// so the agent can parse the server endpoint and start the control listener.
  func readConfigText(at path: String) throws -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return try String(contentsOf: URL(fileURLWithPath: expanded), encoding: .utf8)
  }

  // MARK: - Endpoint parsing

  /// Extracts the peer endpoint from the config using WireGuardKit's own
  /// endpoint parser on the `Endpoint =` line, so the agent reuses the library
  /// rather than reimplementing host and port parsing.
  static func serverEndpoint(fromConfig text: String) -> RelayEndpoint? {
    let lines = text.split(omittingEmptySubsequences: false) { character in
      character == "\n" || character == "\r"
    }
    for rawLine in lines {
      guard let value = endpointValue(inLine: String(rawLine)) else {
        continue
      }
      guard let parsed = Endpoint(from: value) else {
        return nil
      }
      return relayEndpoint(from: parsed)
    }
    return nil
  }

  private static func endpointValue(inLine rawLine: String) -> String? {
    var line = rawLine.trimmingCharacters(in: .whitespaces)
    if let hashIndex = line.firstIndex(of: "#") {
      line = String(line[..<hashIndex]).trimmingCharacters(in: .whitespaces)
    }
    guard let separator = line.firstIndex(of: "=") else {
      return nil
    }
    let key = line[..<separator].trimmingCharacters(in: .whitespaces)
    guard key.caseInsensitiveCompare("Endpoint") == .orderedSame else {
      return nil
    }
    return line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
  }

  private static func relayEndpoint(from endpoint: Endpoint) -> RelayEndpoint {
    let port = endpoint.port.rawValue
    switch endpoint.host {
    case .ipv6(let address):
      return RelayEndpoint(addressFamily: .ipv6, host: "\(address)", port: port)
    case .ipv4(let address):
      return RelayEndpoint(addressFamily: .ipv4, host: "\(address)", port: port)
    case .name(let hostname, _):
      return RelayEndpoint(addressFamily: .ipv4, host: hostname, port: port)
    @unknown default:
      return RelayEndpoint(addressFamily: .ipv4, host: "\(endpoint.host)", port: port)
    }
  }
}

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
  /// Starts the control listener the iPhone dials so the Mac can pair and show
  /// the peer roster before any relay session is armed.
  ///
  /// Concurrent callers share one start rather than each performing their own. This
  /// type is an actor, so it is re-entrant: a guard that reads `controlListener` and
  /// then awaits lets a second caller straight past it. Both would bind the same fixed
  /// port, which succeeds rather than failing because the listener allows endpoint
  /// reuse, and dials then land on either one. The controller keeps whichever finished
  /// last, so the other is unreferenced and its connection handler drops every dial it
  /// receives. The iPhone completes the handshake and calls itself connected while the
  /// Mac's roster stays empty and nothing logs an error.
  ///
  /// Sharing the in-flight start also means a caller returns only once the listener is
  /// actually up, so a caller that immediately arms a peer is not racing the bind.
  func ensureControlListenerStarted() async throws {
    if controlListener != nil {
      return
    }
    if let inFlight = controlListenerStart {
      try await inFlight.value
      return
    }
    let start = Task { try await self.startControlListener() }
    controlListenerStart = start
    defer { controlListenerStart = nil }
    try await start.value
  }

  /// Builds, wires, and starts one control listener, leaving the controller holding it.
  private func startControlListener() async throws {
    controlListenerGeneration += 1
    let generation = controlListenerGeneration
    let fromRebuild = isRebuildingControlListener
    let listener = AgentControlListener()

    // The public-address exchange holds this host's and the iPhone's measured
    // public addresses; the snapshot reads both so the Mac shows `Device / Public`
    // and `Peer / Public`. The controller probes this host on its triggers and
    // the listener sends the result; the listener stores the iPhone's address here.
    let exchange = PublicAddressExchange()
    publicExchange = exchange
    await configurePeerHandlers(on: listener, exchange: exchange, generation: generation)

    try await listener.start()
    // Binding happens after the start call returns, so this listener may already have
    // failed and reported it while this method was suspended. Storing it then would
    // install a listener that publishes nothing and block the replacement already on
    // its way, because the start path returns early whenever a listener object exists.
    guard generation == controlListenerGeneration else {
      await listener.stop()
      return
    }
    controlListener = listener
    controlListenerFromRebuild = fromRebuild

    startEgressMonitor()
    startPublicRefreshTimer()
    // Warm the cached device address so the first connection carries it, and a
    // late-completing probe re-sends to whatever connection is then current.
    Task { await self.refreshDeviceAddress() }
    logger.notice("agent control listener started for pairing")
  }

  /// Publishes the record the iPhone browses for, without waiting to be asked.
  ///
  /// The iPhone finds the Mac by browsing for the control listener, and nothing
  /// else publishes it. The iPhone reaches the Mac over the local network rather
  /// than the mach service, so it cannot send the request that would start the
  /// listener. An agent that waits for a request is therefore unreachable by the
  /// one device it exists to serve.
  ///
  /// A failure here is not fatal. The agent keeps serving requests, and the first
  /// client request retries the same call.
  func startAdvertising() async {
    do {
      try await ensureControlListenerStarted()
    } catch {
      logger.error(
        """
        agent startup advertise failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=await-client-request
        """
      )
    }
  }

  /// Arms the selected peer with the active WireGuard endpoint and starts the
  /// relay bridge, leaving route installation to the existing routing intent.
  func startRelay(wireGuardConfig: String) async throws {
    guard let endpoint = Self.serverEndpoint(fromConfig: wireGuardConfig) else {
      logger.error(
        """
        agent relay start failed \
        reason=no-parseable-endpoint recovery=throw-missing-server-endpoint
        """
      )
      throw AgentTunnelControllerError.missingServerEndpoint
    }
    try await ensureControlListenerStarted()
    guard let controlListener else {
      return
    }

    await controlListener.setServerEndpoint(endpoint)
    configureRelayBridgeHandlers()
    relayBridge.start(serviceName: stableHostName())
    do {
      try await controlListener.armSelectedPeer()
    } catch {
      logger.error(
        "agent relay arm failed details=\(String(describing: error), privacy: .public) recovery=stop-relay-and-rethrow"
      )
      await stopRelay()
      throw error
    }
    relayHosted = true
    logger.notice(
      """
      agent relay armed host=\(endpoint.host, privacy: .public) \
      port=\(endpoint.port, privacy: .public)
      """
    )
  }

  /// Registers listener callbacks that surface peer control messages into
  /// controller state.
  private func configurePeerHandlers(
    on listener: AgentControlListener,
    exchange: PublicAddressExchange,
    generation: Int
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
    // A listener binds its fixed port after its start call returns, so a failure
    // arrives here rather than as a thrown error. The generation travels with the
    // report so a retired listener cannot tear down its replacement.
    await listener.setServingChangedHandler { [weak self] isServing in
      Task { await self?.applyListenerServingChange(generation: generation, isServing: isServing) }
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

  func stopRelay() async {
    routeWithdrawTimer?.cancel()
    routeWithdrawTimer = nil
    routeWithdrawGeneration += 1
    phoneLinkUp = false
    relayHosted = false
    await controlListener?.clearServerEndpoint()
    await controlListener?.sendRouteState(false)
    linkInfo.withLock { $0 = AgentLinkInfo() }
    localLinks.withLock { $0 = [] }
    peerLinks.withLock { $0 = nil }
    agentLinks.withLock { $0 = [] }
    relayBridge.clearSession()
    relayBridge.onEgressInterfaceChange = nil
    relayBridge.onAvailableLinksChange = nil
    relayBridge.onLinkSetChange = nil
    relayBridge.stop()
    logger.notice("agent relay stopped; pairing listener left running")
  }

  /// Tears down everything the agent owns, including the packet tunnel.
  ///
  /// The tunnel extension is a separate process that outlives this one and holds
  /// the installed routes. Stopping only the relay would leave those routes
  /// pointing at a bridge that no longer exists, so traffic would be dropped
  /// rather than falling back to the physical interface. Routing intent is
  /// cleared with it, so a restarted agent and the extension agree.
  func stopControlListener() async {
    // A pending rebuild would otherwise raise a listener after this teardown asked
    // for none.
    cancelListenerRebuild()
    await disableRouting()
    // A stop that lands mid-start would otherwise return before the start assigns its
    // listener, leaving a bound port and a published record with nothing referencing
    // them, which is the state the iPhone dials and nobody reads.
    if let inFlight = controlListenerStart {
      do {
        try await inFlight.value
      } catch {
        // The start already logged why it failed, and a stop has nothing to add: there
        // is no listener to tear down, which is the state this call wants anyway.
        logger.notice("agent control listener stop found a failed start")
      }
    }
    await controlListener?.stop()
    controlListener = nil
    publicExchange = nil
    egressMonitor?.stop()
    egressMonitor = nil
    peerName.withLock { $0 = nil }
    connectedPeers.withLock { $0 = [] }
    egressPath.withLock { $0 = EgressPath() }
    logger.notice("agent control listener stopped")
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
    // Retire the previous monitor. A rebuilt listener starts one again, and an
    // abandoned monitor keeps watching and re-probing the public address for the rest
    // of the agent's life.
    egressMonitor?.stop()
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
  /// reports, which the Mac extension's snapshot does not carry. The saved profile's
  /// state belongs here for the same reason: the provider inside the tunnel cannot
  /// see whether the profile is switched on, so a snapshot forwarded from a running
  /// tunnel would otherwise report nothing for it.
  func augmented(
    _ status: TunnelDaemonStatusSnapshot,
    profileState: TunnelVPNProfileState?
  ) -> TunnelDaemonStatusSnapshot {
    var merged = status
    merged.vpnProfileState = profileState
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
    // Whether an iPhone can find this Mac at all. A listener that lost its port is
    // invisible in every other field, so no peer ever appears and nothing says why.
    merged.advertising = TunnelAdvertisingState(isAdvertising: controlListener != nil)
    merged.configLibrary = configStore.summaries()
    merged.activeConfigID = configStore.activeID
    merged.configDrift = configDriftMessage
    // Surface a failed detached relay start so the app reverts the switch and shows
    // the error. A provider-reported error already on the snapshot takes precedence.
    // A switched-off profile explains the failure and carries an action of its own, so
    // the stale start error is withheld there rather than outranking it and leaving a
    // routing control the user cannot make work.
    if merged.lastError == nil, profileState != .disabled {
      merged.lastError = lastStartError
    }
    return merged
  }

  // MARK: - Routing control

  /// Drives the relay session lifetime from the Route traffic switch: turning routing
  /// on starts the relay session and turning it off tears it down. Routing is a live
  /// in-memory value with no persistence, so it resets to off on agent start. The
  /// phone's control link calls this too, so the phone's switch shares the behavior.
  func setRoutingEnabled(_ enabled: Bool) async {
    if enabled {
      await enableRouting()
    } else {
      await disableRouting()
    }
  }

  /// Turns routing on. It bumps the start generation, classifies the precondition
  /// synchronously before any await, then marks intent and starts only on a branch that
  /// will proceed. Resolving the config before marking intent means a `handlePhoneLink`
  /// interleaving at the first await never sees `routingEnabled=true` for a request that
  /// will fail, so the no-config bail installs no routes. Reconciling against
  /// `relayHosted` rather than the macOS VPN session means a stale connected session left
  /// by a crash never makes the switch read on without a hosted relay. The no-config bail
  /// reverts the intent and sets `lastStartError` so the app surfaces the failure.
  private func enableRouting() async {
    routingGeneration += 1
    let generation = routingGeneration

    // Resolve the active config synchronously, before any await, so the precondition is
    // decided against a stable read and no interleaving callback observes a half-applied
    // intent.
    let activeID = configStore.activeID
    let configText = activeID.flatMap { configStore.text(forID: $0) }

    switch routingEnablePrecondition(
      relayHosted: relayHosted,
      hasResolvableActiveConfig: configText != nil
    ) {
    case .relayHostedReady:
      routingEnabled = true
      lastStartError = nil
      await controlListener?.sendRoutingIntent(true)
      logger.notice(
        "agent routing enabled phoneLinkUp=\(self.phoneLinkUp, privacy: .public)"
      )
      if phoneLinkUp {
        await signalRouteState(true)
      }
    case .noActiveConfig:
      routingEnabled = false
      lastStartError = noActiveConfigSelectedMessage
      await controlListener?.sendRoutingIntent(false)
      logger.notice("agent routing enable found no active config recovery=skip-start")
    case .activeConfigReady:
      guard let activeID, let configText else {
        return
      }
      routingEnabled = true
      // Claimed before the first suspension, so an unavailable-profile notification
      // arriving while the intent is being announced cannot cancel this start.
      settlingStartGeneration = generation
      lastStartError = nil
      await controlListener?.sendRoutingIntent(true)
      logger.notice(
        "agent routing enabled phoneLinkUp=\(self.phoneLinkUp, privacy: .public)"
      )
      startRelaySessionDetached(
        configText: configText, configID: activeID, generation: generation)
    }
  }

  /// Turns routing off. It bumps the start generation so an in-flight detached start is
  /// superseded, withdraws the program routes, then stops the relay session and the
  /// relay bridge through the existing stop path. Shared by the routing switch, the
  /// stop request, and active-config deletion so every teardown clears the same state.
  func disableRouting() async {
    routingGeneration += 1
    routingEnabled = false
    // Any start this supersedes is no longer settling, and clearing here means a start
    // that stalls before it runs cannot strand the routing-intent reconciliation.
    settlingStartGeneration = nil
    lastStartError = nil
    await controlListener?.sendRoutingIntent(false)
    logger.notice("agent routing disabled recovery=stop-session-and-relay")
    await signalRouteState(false)
    _ = await handleStopTunnel()
  }

  /// Starts the relay session off the XPC reply path so the app's status polls animate
  /// connecting to on rather than blocking on `waitForSessionConnected`. The captured
  /// generation lets `applyStartOutcome` detect a start that a later enable or disable
  /// superseded.
  private func startRelaySessionDetached(
    configText: String,
    configID: UUID,
    generation: Int
  ) {
    logger.notice(
      "agent routing enable starting relay detached configID=\(configID.uuidString, privacy: .public)"
    )
    let previous = relayStartTask
    settlingStartGeneration = generation
    relayStartTask = Task { [weak self] in
      await previous?.value
      await self?.runRelayStart(configText: configText, configID: configID, generation: generation)
    }
  }

  /// Runs one serialized detached start. A start that a later toggle superseded while it
  /// waited for the prior start to finish bows out here before doing any work, so two
  /// `startTunnel` runs never overlap.
  private func runRelayStart(configText: String, configID: UUID, generation: Int) async {
    // Only the start that staked this claim releases it, so a superseded start cannot
    // clear the claim a newer one is relying on.
    defer {
      if settlingStartGeneration == generation {
        settlingStartGeneration = nil
      }
    }
    guard generation == routingGeneration else {
      return
    }
    let response = await startTunnel(configText: configText, configID: configID)
    await applyStartOutcome(response, generation: generation)
  }

  /// Records a detached start's outcome. A start that a later enable or disable
  /// superseded does not record its result; when the desired state is now off it tears
  /// down any session the stale start brought up after the disable ran. A current start
  /// that failed reverts routing and stops the partial session, bridge, and routes so
  /// status reads off plus the error. A current start that succeeded clears any prior
  /// error.
  private func applyStartOutcome(_ response: AgentControlResponse, generation: Int) async {
    guard generation == routingGeneration else {
      if !routingEnabled {
        _ = await handleStopTunnel()
      }
      return
    }
    guard let failure = response.failure else {
      lastStartError = nil
      return
    }
    lastStartError = failure.message
    routingEnabled = false
    await controlListener?.sendRoutingIntent(false)
    await signalRouteState(false)
    _ = await handleStopTunnel()
    logger.error(
      """
      agent detached relay start failed \
      code=\(failure.errorCode.rawValue, privacy: .public) \
      message=\(failure.message, privacy: .public) recovery=revert-routing-off-and-stop
      """
    )
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

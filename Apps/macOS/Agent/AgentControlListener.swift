//
//  AgentControlListener.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

private let tcpKeepaliveIdleSeconds = 10
private let tcpKeepaliveIntervalSeconds = 5
private let tcpKeepaliveRetryCount = 3
private let fallbackHostName = "Cell Tunnel Mac"

// MARK: - Stable host name

/// The machine name used for the relay Bonjour services, the ComputerName. It does
/// not read `ProcessInfo.processInfo.hostName`, which returns the transient mDNS
/// hostname; with Cloudflare WARP running that is `connectivity-check.warp-svc`, so
/// the iPhone would show that instead of the Mac. The ComputerName is a stable
/// system setting, so the peer name stays correct.
func stableHostName() -> String {
  Host.current().localizedName ?? fallbackHostName
}

// MARK: - ControlPeer

/// One iPhone holding a control connection to the agent. The agent keeps every
/// dialed-in iPhone here so the Mac can list and choose among them; only the
/// selected peer is handed a relay-session id, so only its data links are admitted.
/// `id` is minted once on handshake and reused as the relay-session id when the peer
/// is selected, so selecting a peer rebinds the data plane to it.
private struct ControlPeer {
  let id: UInt64
  let connection: NWConnection
  /// A monotonic accept order, so the newest connection for a device wins when one
  /// device briefly holds two connections across a reconnect.
  let sequence: Int
  /// The iPhone's stable per-install id from its status push, `nil` until the first
  /// arrives or for an old app that does not send one. It is the roster id and the key
  /// the Mac persists a selection against, so a reconnect maps back to the same device.
  var deviceID: String?
  /// The iPhone's display name from its status push, `nil` until the first arrives.
  var deviceName: String?
  /// Whether this iPhone's status push carried `availableLinks`, the signal that it
  /// decodes the link-inventory message. Tracked per peer so an old iPhone never
  /// receives a message it cannot decode.
  var supportsLinkInventory: Bool
}

// MARK: - AgentControlListener

/// Hosts the control link in the agent, a normal process that receives inbound from
/// the iPhones over the local link. It advertises the control Bonjour service and
/// accepts every iPhone that dials in, holding each as a `ControlPeer` so the Mac
/// can choose which one carries egress. The iPhone owns the dial, so pairing can
/// complete before the relay is armed; the Mac later sends the WireGuard server
/// endpoint and relay-session only to the selected peer when relay start is
/// requested.
actor AgentControlListener {
  var serverEndpoint: RelayEndpoint?
  private let connectionQueue = DispatchQueue(label: "io.goodkind.celltunnel.agent.control")
  private var listener: NWListener?
  /// Every iPhone currently holding a control connection, keyed by its minted id.
  private var peers: [UInt64: ControlPeer] = [:]
  /// The minted id of the live connection currently bound as egress, the value
  /// installed in the bridge, or `nil` when nothing is bound. Cleared when that
  /// connection drops; re-set when the chosen device reconnects.
  private var selectedPeerID: UInt64?
  /// The stable device id the user chose, persisted in `EgressSelectionStore`, so the
  /// same device re-binds automatically whenever it reappears. `nil` for no selection
  /// or a legacy peer chosen by connection handle. Loaded at start from the store.
  private var selectedDeviceID: String?
  /// A monotonic counter stamped onto each accepted connection, so the newest wins
  /// when one device holds two connections briefly across a reconnect.
  private var acceptCounter = 0
  private var didStart = false
  /// This Mac's latest relay-link candidates, published by the controller as the
  /// bridge's link set changes, sent to the selected peer on each change and when
  /// the capability first appears.
  private var latestLinkInventory: [RelayLinkSummary] = []

  /// Invoked with the user's routing choice when the iPhone pushes it over the
  /// control link, so the controller can install or withdraw the program routes.
  /// Internal so the message-routing extension file can drive it.
  var onSetRoutingEnabled: (@Sendable (Bool) -> Void)?
  /// Invoked with the iPhone's measured public address received over the control
  /// link, so the public-address exchange stores it as the peer's address.
  /// Internal so the message-routing extension file can drive it.
  var onPeerPublicAddress: (@Sendable (AddressPair) -> Void)?
  /// Invoked with the selected iPhone's device name carried in its status push, so
  /// the controller reports it as the connected peer name.
  private var onPeerDeviceName: (@Sendable (String) -> Void)?
  /// Invoked with the selected iPhone's relay-link candidates carried in its status
  /// push, so the controller reports them as the peer available links.
  private var onPeerAvailableLinks: (@Sendable ([RelayLinkSummary]) -> Void)?
  /// Invoked when the selected control connection ends, so the controller clears the
  /// connected peer name and the bridge's admit session. A non-selected peer ending
  /// does not fire it; the roster callback alone reflects that.
  private var onConnectionDropped: (@Sendable () -> Void)?
  /// Invoked with the selected peer's id each time selection installs it, so the
  /// controller installs it into the relay bridge as the value relay primes must
  /// carry to be admitted.
  private var onSessionEstablished: (@Sendable (UInt64) -> Void)?
  /// Invoked whenever the roster of connected iPhones changes, so the controller
  /// surfaces it in the status snapshot for the Mac selector.
  private var onRosterChanged: (@Sendable ([ConnectedPeer]) -> Void)?
  /// This host's latest measured public address, set by the controller as it probes.
  /// It is sent on each accepted control connection once that connection's handshake
  /// completes, so a freshly connected peer receives it at once.
  private var latestDeviceAddress = AddressPair.empty
  /// Answers the current routing intent and installed-route state at handshake time,
  /// so every accepted connection is synced immediately instead of waiting for the
  /// next change or status poll. Set by the controller before `start()`.
  private var routingSyncProvider: (@Sendable () async -> (intent: Bool, installed: Bool))?

  init(serverEndpoint: RelayEndpoint? = nil) {
    self.serverEndpoint = serverEndpoint
  }

  // MARK: - Selected connection

  /// The control connection of the iPhone the Mac routes egress through, the target
  /// of every "send to the current peer" path, or `nil` when none is selected.
  var selectedConnection: NWConnection? {
    currentSelectedPeer()?.connection
  }

  // MARK: - Lifecycle

  func start() throws {
    guard !didStart else {
      return
    }
    didStart = true
    // Load the remembered egress device so it re-binds as soon as it reconnects, which
    // restores the user's choice across the sleep/wake reconnects and an agent restart.
    selectedDeviceID = EgressSelectionStore.selectedDeviceID()
    try startListener()
  }

  func stop() {
    for peer in peers.values {
      peer.connection.cancel()
    }
    peers.removeAll()
    selectedPeerID = nil
    selectedDeviceID = nil
    listener?.cancel()
    listener = nil
    didStart = false
    logger.notice("agent control listener stopped")
  }

  // MARK: - Listener

  private func startListener() throws {
    let parameters = NWParameters(tls: nil, tcp: tcpOptions())
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true
    parameters.defaultProtocolStack.applicationProtocols.insert(
      RelayControlFramerSupport.framerOptions(),
      at: 0
    )

    let nwListener: NWListener
    do {
      if let port = NWEndpoint.Port(rawValue: relayControlListenerDefaultPort) {
        nwListener = try NWListener(using: parameters, on: port)
      } else {
        nwListener = try NWListener(using: parameters)
      }
    } catch {
      logger.error(
        """
        agent control listener create failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=throw-listener-failed
        """
      )
      throw AgentControlListenerError.listenerFailed(error.localizedDescription)
    }

    let serviceName = stableHostName()
    nwListener.service = NWListener.Service(
      name: serviceName,
      type: relayControlServiceType
    )
    nwListener.stateUpdateHandler = { state in
      applyListenerState(state)
    }
    nwListener.newConnectionHandler = { [weak self] connection in
      Task { await self?.acceptConnection(connection) }
    }
    nwListener.start(queue: connectionQueue)
    listener = nwListener
    logger.notice(
      """
      agent control listener starting service=\(relayControlServiceType, privacy: .public) \
      name=\(serviceName, privacy: .public) \
      port=\(relayControlListenerDefaultPort, privacy: .public)
      """
    )
  }

  private func acceptConnection(_ newConnection: NWConnection) async {
    logger.notice(
      """
      agent control listener accepting connection \
      endpoint=\(String(describing: newConnection.endpoint), privacy: .public)
      """
    )
    let peerID = UInt64.random(in: .min ... .max)
    acceptCounter += 1
    let sequence = acceptCounter
    newConnection.stateUpdateHandler = { [weak self] state in
      applyAcceptedConnectionState(state)
      switch state {
      case .cancelled, .failed:
        Task { await self?.noteConnectionEnded(newConnection) }
      default:
        break
      }
    }
    newConnection.start(queue: connectionQueue)
    // Record the control connection at once so the Mac can show the peer roster
    // before any relay session is armed.
    peers[peerID] = ControlPeer(
      id: peerID,
      connection: newConnection,
      sequence: sequence,
      deviceID: nil,
      deviceName: nil,
      supportsLinkInventory: false
    )
    startReceiveLoop(on: newConnection, peerID: peerID)
    // Sync the routing truth to this connection: the persisted intent and a
    // not-installed route state, since a freshly connected iPhone is not the
    // egress peer. Selecting it and bringing its link up upgrades the route state.
    if let routingSyncProvider {
      let sync = await routingSyncProvider()
      await sendRoutingIntent(sync.intent, on: newConnection)
      await sendRouteState(false, on: newConnection)
    }
    if !latestDeviceAddress.isEmpty {
      await sendPublicAddress(latestDeviceAddress, on: newConnection)
    }
    publishRoster()
  }

  // MARK: - Egress selection

  /// Selects which connected iPhone the Mac routes egress through, by the roster id
  /// (a stable device id, or a legacy connection handle for an app that sends none).
  /// A device-id selection is persisted so the same device re-binds whenever it
  /// reappears; a legacy handle selection binds the connection but persists nothing.
  /// An unknown id is ignored.
  func selectPeer(peerID: String) async {
    guard let peer = resolvePeer(reference: peerID) else {
      logger.error(
        "agent control select-egress rejected reason=unknown-peer id=\(peerID, privacy: .public)"
      )
      return
    }
    selectedDeviceID = peer.deviceID
    EgressSelectionStore.setSelectedDeviceID(peer.deviceID)
    logger.notice(
      "agent control selected egress device=\(peer.deviceID ?? "legacy", privacy: .public)")
    await selectCurrentPeer(peer)
    if serverEndpoint != nil {
      do {
        try await arm(peer)
      } catch {
        logger.error(
          """
          agent control arm on select failed \
          error=\(error.localizedDescription, privacy: .public) recovery=keep-selection
          """
        )
      }
    }
  }

  /// Resolves a roster id to a live peer: a stable device id wins, taking the newest
  /// connection when one device holds two across a reconnect, else a legacy handle.
  private func resolvePeer(reference: String) -> ControlPeer? {
    let byDevice = peers.values
      .filter { $0.deviceID == reference }
      .max { $0.sequence < $1.sequence }
    if let byDevice {
      return byDevice
    }
    guard let handle = UInt64(reference) else {
      return nil
    }
    return peers[handle]
  }

  /// Marks a peer as the current selection and mirrors the routing truth to that
  /// connection. Selection alone does not arm the relay session.
  private func selectCurrentPeer(_ peer: ControlPeer) async {
    selectedPeerID = peer.id
    if let routingSyncProvider {
      let sync = await routingSyncProvider()
      await sendRoutingIntent(sync.intent, on: peer.connection)
      await sendRouteState(false, on: peer.connection)
    }
    if let deviceName = peer.deviceName {
      onPeerDeviceName?(deviceName)
    }
    publishRoster()
  }

  /// Arms the selected peer for relay traffic by sending the endpoint and the
  /// relay-session id. The selected peer then primes its data links under this id.
  private func arm(_ peer: ControlPeer) async throws {
    try await sendSetServerEndpoint(on: peer.connection)
    peers[peer.id]?.supportsLinkInventory = false
    logger.notice("agent control armed egress connection id=\(peer.id, privacy: .public)")
    onSessionEstablished?(peer.id)
    await sendRelaySession(peer.id, on: peer.connection)
  }

  // MARK: - Status receive loop

  private func startReceiveLoop(on connection: NWConnection, peerID: UInt64) {
    connection.receiveMessage { [weak self] data, _, _, error in
      if let error {
        logger.error(
          "agent control receive failed error=\(error.localizedDescription, privacy: .public)"
        )
        return
      }
      if let data, !data.isEmpty {
        Task { [weak self] in
          await self?.handleStreamPayload(data, fromPeerID: peerID)
        }
      }
      Task { [weak self] in
        await self?.continueReceiveLoop(on: connection, peerID: peerID)
      }
    }
  }

  private func continueReceiveLoop(on connection: NWConnection, peerID: UInt64) {
    startReceiveLoop(on: connection, peerID: peerID)
  }
}

// MARK: - Handlers and public-address send

extension AgentControlListener {
  func tcpOptions() -> NWProtocolTCP.Options {
    let options = NWProtocolTCP.Options()
    options.enableKeepalive = true
    options.keepaliveIdle = tcpKeepaliveIdleSeconds
    options.keepaliveInterval = tcpKeepaliveIntervalSeconds
    options.keepaliveCount = tcpKeepaliveRetryCount
    options.noDelay = true
    return options
  }

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

  /// Sets the WireGuard server endpoint the selected peer should relay to when the
  /// relay is armed.
  func setServerEndpoint(_ endpoint: RelayEndpoint) {
    serverEndpoint = endpoint
  }

  /// Clears any armed relay endpoint while leaving the control pairing alive.
  func clearServerEndpoint() {
    serverEndpoint = nil
  }

  /// Arms whichever peer is currently selected, whether it was selected explicitly
  /// in this session or restored from the remembered device id.
  func armSelectedPeer() async throws {
    guard let peer = currentSelectedPeer() else {
      throw AgentControlListenerError.connectionFailed("no selected peer connection")
    }
    try await arm(peer)
  }

  /// Whether the listener currently has a selected live peer connection.
  func hasSelectedPeer() -> Bool {
    currentSelectedPeer() != nil
  }

  /// Sends the selected peer's relay-session id to its iPhone, so the phone stamps it
  /// on every relay prime and the bridge admits its links. Sent on the selected
  /// connection directly, since it is the first thing after selection.
  func sendRelaySession(_ sessionID: UInt64, on connection: NWConnection) async {
    do {
      try await send(
        .relaySession(RelayControlMessage.RelaySession(sessionID: sessionID)),
        on: connection
      )
    } catch {
      logger.error(
        """
        agent control relay-session send failed \
        error=\(error.localizedDescription, privacy: .public) recovery=await-next-selection
        """
      )
    }
  }

  /// Registers the provider answering the current routing intent and installed state,
  /// queried once per accepted connection so the handshake syncs both.
  func setRoutingSyncProvider(
    _ provider: @escaping @Sendable () async -> (intent: Bool, installed: Bool)
  ) {
    routingSyncProvider = provider
  }

  /// Removes the ended connection from the roster. When the selected peer ends, it
  /// clears the selection and fires the dropped handler so the controller clears the
  /// peer name and the bridge admit session. A non-selected peer ending only updates
  /// the roster. A losing transient connection from a multi-interface dial was never
  /// added, so its end finds no peer and is ignored.
  func noteConnectionEnded(_ ended: NWConnection) {
    guard let id = peerID(of: ended) else {
      return
    }
    peers.removeValue(forKey: id)
    if selectedPeerID == id {
      // Unbind the live connection and idle the data plane, but keep the remembered
      // device id so the device re-binds on its next connection. The selection is
      // forgotten only by an explicit different pick or a reset.
      selectedPeerID = nil
      onConnectionDropped?()
      logger.notice("agent control bound connection ended; egress unbound, choice kept")
    }
    publishRoster()
  }

  private func peerID(of connection: NWConnection) -> UInt64? {
    for (id, peer) in peers where peer.connection === connection {
      return id
    }
    return nil
  }

  /// Surfaces the fields a received status carries: the sending iPhone's device name,
  /// recorded against its roster entry and reported as the connected peer name only
  /// for the selected peer, and its link candidates, reported only for the selected
  /// peer since the peer `Available Interfaces` row is about the egress peer. Both the
  /// status-loop path routes here with the sending peer's id.
  func surface(status snapshot: RelayControlMessage.Status, fromPeerID id: UInt64) {
    if let deviceID = snapshot.deviceID, !deviceID.isEmpty, peers[id]?.deviceID != deviceID {
      peers[id]?.deviceID = deviceID
      publishRoster()
      // Sticky re-bind: when the remembered device reappears (a sleep/wake reconnect or
      // a fresh start), bind egress back to it with no manual re-pick. Binds only the
      // device the user already chose, and only admits its link; routing is unchanged.
      if deviceID == selectedDeviceID, selectedPeerID != id, let peer = peers[id] {
        Task {
          await self.selectCurrentPeer(peer)
          if self.serverEndpoint != nil {
            do {
              try await self.arm(peer)
            } catch {
              logger.error(
                """
                agent control re-arm failed \
                error=\(error.localizedDescription, privacy: .public) recovery=keep-selection
                """
              )
            }
          }
        }
      }
    }
    if let deviceName = snapshot.deviceName, !deviceName.isEmpty {
      if peers[id]?.deviceName != deviceName {
        peers[id]?.deviceName = deviceName
        publishRoster()
      }
      if id == selectedPeerID {
        onPeerDeviceName?(deviceName)
      }
    }
    if let links = snapshot.availableLinks, id == selectedPeerID {
      onPeerAvailableLinks?(links)
      if peers[id]?.supportsLinkInventory != true {
        peers[id]?.supportsLinkInventory = true
        Task { await self.sendLinkInventoryToCurrent() }
      }
    }
  }

  /// Publishes the current roster of connected iPhones, the selected one flagged,
  /// sorted by id for a stable rendering. Peers with a stable device id are deduped to
  /// one entry per device (the newest connection), so a reconnecting device stays a
  /// single stable row keyed by its device id; a legacy peer without one keeps its
  /// per-connection handle as the id.
  private func publishRoster() {
    var newestByDevice: [String: ControlPeer] = [:]
    var legacyPeers: [ControlPeer] = []
    for peer in peers.values {
      guard let deviceID = peer.deviceID else {
        legacyPeers.append(peer)
        continue
      }
      if let existing = newestByDevice[deviceID], existing.sequence >= peer.sequence {
        continue
      }
      newestByDevice[deviceID] = peer
    }
    var roster = newestByDevice.values.map { peer in
      ConnectedPeer(
        id: peer.deviceID ?? String(peer.id),
        name: peer.deviceName ?? "",
        isSelected: peer.deviceID == selectedDeviceID
      )
    }
    roster += legacyPeers.map { peer in
      ConnectedPeer(
        id: String(peer.id),
        name: peer.deviceName ?? "",
        isSelected: selectedDeviceID == nil && peer.id == selectedPeerID
      )
    }
    onRosterChanged?(roster.sorted { $0.id < $1.id })
  }

  private func currentSelectedPeer() -> ControlPeer? {
    if let selectedPeerID, let selected = peers[selectedPeerID] {
      return selected
    }
    guard let selectedDeviceID else {
      return nil
    }
    return peers.values
      .filter { $0.deviceID == selectedDeviceID }
      .max { $0.sequence < $1.sequence }
  }

  /// Records this host's latest measured public address, sent on each accepted
  /// connection once its handshake completes.
  func setDeviceAddress(_ addresses: AddressPair) {
    latestDeviceAddress = addresses
  }

  /// Records this Mac's latest relay-link candidates and pushes them to the selected
  /// iPhone when it is capable, so the iPhone's peer row tracks link churn.
  func publishLinkInventory(_ links: [RelayLinkSummary]) async {
    latestLinkInventory = links
    await sendLinkInventoryToCurrent()
  }

  /// Sends the latest inventory on the selected control connection. A no-op without a
  /// selected peer or before that peer signals the capability.
  private func sendLinkInventoryToCurrent() async {
    guard let selectedPeerID, peers[selectedPeerID]?.supportsLinkInventory == true,
      let connection = peers[selectedPeerID]?.connection
    else {
      return
    }
    do {
      try await send(
        .linkInventory(RelayControlMessage.LinkInventory(links: latestLinkInventory)),
        on: connection
      )
    } catch {
      logger.error(
        """
        agent control link-inventory send failed \
        count=\(self.latestLinkInventory.count, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public) recovery=await-next-change
        """
      )
    }
  }

  /// Sends this host's measured public address on the selected control connection.
  /// Used by the path-change, routing, and periodic refresh triggers. A no-op when no
  /// iPhone is selected.
  func sendPublicAddressToCurrent(_ addresses: AddressPair) async {
    guard let selectedConnection else {
      return
    }
    await sendPublicAddress(addresses, on: selectedConnection)
  }

  /// Sends this host's measured public address on a specific control connection, so a
  /// freshly accepted connection carries it as part of its own handshake.
  func sendPublicAddress(_ addresses: AddressPair, on connection: NWConnection) async {
    do {
      try await send(
        .publicAddress(RelayControlMessage.PublicAddress(addresses: addresses)),
        on: connection
      )
    } catch {
      logger.error(
        """
        agent control public address send failed \
        error=\(error.localizedDescription, privacy: .public) recovery=await-next-change
        """
      )
    }
  }
}

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

// MARK: - AgentControlListener

/// Hosts the control link in the agent, a normal process that receives inbound
/// from the iPhone over the local link. It advertises the control Bonjour
/// service and listens for the iPhone to dial in. On each accepted connection it
/// sends the WireGuard server endpoint, waits for the acknowledgement, then
/// consumes the iPhone status pushes. The iPhone owns the dial; the
/// `set-server-endpoint` message travels from agent to iPhone.
actor AgentControlListener {
  private let serverEndpoint: RelayEndpoint
  private let connectionQueue = DispatchQueue(label: "io.goodkind.celltunnel.agent.control")
  private var listener: NWListener?
  private var connection: NWConnection?
  private var didStart = false
  /// This Mac's latest relay-link candidates, published by the controller as
  /// the bridge's link set changes, sent to a capable peer on each change and
  /// when the capability first appears.
  private var latestLinkInventory: [RelayLinkSummary] = []
  /// Whether the connected iPhone's status push carried `availableLinks`, the
  /// signal that it decodes the link-inventory message. Reset when a new
  /// connection is promoted, so an old iPhone never receives a message it
  /// cannot decode.
  private var peerSupportsLinkInventory = false

  /// Invoked with the user's routing choice when the iPhone pushes it over the
  /// control link, so the controller can install or withdraw the program routes.
  /// Internal so the message-routing extension file can drive it.
  var onSetRoutingEnabled: (@Sendable (Bool) -> Void)?
  /// Invoked with the iPhone's measured public address received over the control
  /// link, so the public-address exchange stores it as the peer's address.
  /// Internal so the message-routing extension file can drive it.
  var onPeerPublicAddress: (@Sendable (AddressPair) -> Void)?
  /// Invoked with the iPhone's device name carried in its status push, so the
  /// controller reports it as the connected peer name.
  private var onPeerDeviceName: (@Sendable (String) -> Void)?
  /// Invoked with the iPhone's relay-link candidates carried in its status push,
  /// so the controller reports them as the peer available links.
  private var onPeerAvailableLinks: (@Sendable ([RelayLinkSummary]) -> Void)?
  /// Invoked when the primary control connection ends, so the controller clears
  /// the connected peer name. The peer name follows the control link, not the
  /// data link, so a brief data-link blip does not clear it.
  private var onConnectionDropped: (@Sendable () -> Void)?
  /// This host's latest measured public address, set by the controller as it
  /// probes. It is sent on each accepted control connection once that connection's
  /// handshake completes, so a freshly connected peer receives it at once.
  private var latestDeviceAddress = AddressPair.empty
  /// Answers the current routing intent and installed-route state at handshake
  /// time, so every accepted connection is synced immediately instead of waiting
  /// for the next change or status poll. Set by the controller before `start()`.
  private var routingSyncProvider: (@Sendable () async -> (intent: Bool, installed: Bool))?

  init(serverEndpoint: RelayEndpoint) {
    self.serverEndpoint = serverEndpoint
  }

  // MARK: - Lifecycle

  func start() throws {
    guard !didStart else {
      return
    }
    didStart = true
    try startListener()
  }

  func stop() {
    connection?.cancel()
    connection = nil
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
    let previous = connection
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
    do {
      try await sendSetServerEndpoint(on: newConnection)
      // The handshake completed, so promote this connection to the primary and
      // retire any prior one. A transient connection that loses the dial race
      // and never handshakes is dropped in the catch without disturbing the
      // live connection, so a multi-interface dial does not tear down a good link.
      connection = newConnection
      peerSupportsLinkInventory = false
      previous?.cancel()
      startReceiveLoop(on: newConnection)
      if !latestDeviceAddress.isEmpty {
        await sendPublicAddress(latestDeviceAddress, on: newConnection)
      }
      // Sync the routing truth on every accepted connection: a reconnect or app
      // relaunch otherwise shows stale intent and route state until the next
      // change, because the phone clears its mirror when the control link drops.
      if let routingSyncProvider {
        let sync = await routingSyncProvider()
        await sendRoutingIntent(sync.intent)
        await sendRouteState(sync.installed)
      }
    } catch {
      logger.error(
        """
        agent control handshake failed \
        error=\(error.localizedDescription, privacy: .public) \
        recovery=drop-this-connection
        """
      )
      newConnection.cancel()
    }
  }

  // MARK: - Handshake

  private func sendSetServerEndpoint(on connection: NWConnection) async throws {
    logger.notice(
      """
      agent control sending set-server-endpoint \
      host=\(self.serverEndpoint.host, privacy: .public) \
      port=\(self.serverEndpoint.port, privacy: .public)
      """
    )
    let message = RelayControlMessage.setServerEndpoint(
      RelayControlMessage.SetServerEndpoint(endpoint: serverEndpoint)
    )
    try await send(message, on: connection)
    try await awaitAcknowledge(on: connection, requestKind: "set-server-endpoint")
  }

  /// Sends the agent's confirmed route state to the connected iPhone, so the app
  /// reports installed routes from the agent's truth rather than the local routing
  /// intent. A no-op when no iPhone is connected.
  func sendRouteState(_ installed: Bool) async {
    guard let connection else {
      return
    }
    do {
      try await send(
        .routeState(RelayControlMessage.RouteState(installed: installed)),
        on: connection
      )
    } catch {
      logger.error(
        """
        agent control route-state send failed installed=\(installed, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public) recovery=await-next-change
        """
      )
    }
  }

  /// Sends the agent's persisted routing intent to the connected iPhone, the
  /// value behind the Route traffic switch, so the phone mirrors the agent's
  /// truth instead of holding its own copy. A no-op when no iPhone is connected.
  func sendRoutingIntent(_ enabled: Bool) async {
    guard let connection else {
      return
    }
    do {
      try await send(
        .routingIntent(RelayControlMessage.RoutingIntent(enabled: enabled)),
        on: connection
      )
    } catch {
      logger.error(
        """
        agent control routing-intent send failed enabled=\(enabled, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public) recovery=await-next-change
        """
      )
    }
  }

  private func send(
    _ message: RelayControlMessage,
    on connection: NWConnection
  ) async throws {
    let payload = try RelayControlMessageCodec.encode(message)
    let framerMessage = NWProtocolFramer.Message(definition: RelayControlFramer.definition)
    let context = NWConnection.ContentContext(
      identifier: message.kindLabel,
      metadata: [framerMessage]
    )
    let _: Void = try await withCheckedThrowingContinuation { continuation in
      connection.send(
        content: payload,
        contentContext: context,
        isComplete: true,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          continuation.resume()
        }
      )
    }
    logger.notice(
      """
      agent control sent kind=\(message.kindLabel, privacy: .public) \
      bytes=\(payload.count, privacy: .public)
      """
    )
  }

  private func awaitAcknowledge(
    on connection: NWConnection,
    requestKind: String
  ) async throws {
    let received = try await receiveOne(on: connection)
    switch received {
    case .acknowledge(let payload) where payload.requestKind == requestKind:
      logger.notice(
        """
        agent control acknowledge received \
        requestKind=\(payload.requestKind, privacy: .public)
        """
      )
    case .error(let failure):
      throw AgentControlListenerError.remoteError(
        AgentControlListenerError.RemoteErrorPayload(
          code: failure.code,
          message: failure.message
        )
      )
    case .status(let snapshot):
      logger.notice(
        """
        agent control received status before ack \
        hasCellularPath=\(snapshot.hasCellularPath, privacy: .public)
        """
      )
      surface(status: snapshot)
      try await awaitAcknowledge(on: connection, requestKind: requestKind)
    case .publicAddress(let payload):
      onPeerPublicAddress?(payload.addresses)
      try await awaitAcknowledge(on: connection, requestKind: requestKind)
    default:
      throw AgentControlListenerError.acknowledgeMissing
    }
  }

  private func receiveOne(on connection: NWConnection) async throws -> RelayControlMessage {
    try await withCheckedThrowingContinuation { continuation in
      connection.receiveMessage { data, _, _, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let data, !data.isEmpty else {
          continuation.resume(
            throwing: AgentControlListenerError.connectionFailed(
              "empty payload received"
            )
          )
          return
        }
        do {
          let decoded = try RelayControlMessageCodec.decode(data)
          continuation.resume(returning: decoded)
        } catch {
          logger.error(
            """
            agent control decode failed during receive \
            error=\(error.localizedDescription, privacy: .public)
            """
          )
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - Status receive loop

  private func startReceiveLoop(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      if let error {
        logger.error(
          "agent control receive failed error=\(error.localizedDescription, privacy: .public)"
        )
        return
      }
      if let data, !data.isEmpty {
        Task { [weak self] in
          await self?.handleStreamPayload(data)
        }
      }
      Task { [weak self] in
        await self?.continueReceiveLoop(on: connection)
      }
    }
  }

  private func continueReceiveLoop(on connection: NWConnection) {
    startReceiveLoop(on: connection)
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

  /// Registers the control-connection-dropped handler before the listener starts.
  func setConnectionDroppedHandler(_ handler: @escaping @Sendable () -> Void) {
    onConnectionDropped = handler
  }

  /// Registers the provider answering the current routing intent and installed
  /// state, queried once per accepted connection so the handshake syncs both.
  func setRoutingSyncProvider(
    _ provider: @escaping @Sendable () async -> (intent: Bool, installed: Bool)
  ) {
    routingSyncProvider = provider
  }

  /// Fires the dropped handler when the primary control connection ends, so the
  /// controller clears the peer name. A losing transient connection from a
  /// multi-interface dial is not the primary, so its end is ignored.
  func noteConnectionEnded(_ ended: NWConnection) {
    guard connection === ended else {
      return
    }
    connection = nil
    onConnectionDropped?()
    logger.notice("agent control primary connection ended; peer name cleared")
  }

  /// Surfaces the fields a received status carries to the controller: the iPhone's
  /// device name when present. Both the pre-acknowledge status and the status-loop
  /// status flow through here, so the surfacing lives in one place.
  func surface(status snapshot: RelayControlMessage.Status) {
    if let deviceName = snapshot.deviceName, !deviceName.isEmpty {
      onPeerDeviceName?(deviceName)
    }
    if let links = snapshot.availableLinks {
      onPeerAvailableLinks?(links)
      if !peerSupportsLinkInventory {
        peerSupportsLinkInventory = true
        Task { await self.sendLinkInventoryToCurrent() }
      }
    }
  }

  /// Records this host's latest measured public address, sent on each accepted
  /// connection once its handshake completes.
  func setDeviceAddress(_ addresses: AddressPair) {
    latestDeviceAddress = addresses
  }

  /// Records this Mac's latest relay-link candidates and pushes them to a
  /// capable connected iPhone, so the iPhone's peer row tracks link churn.
  func publishLinkInventory(_ links: [RelayLinkSummary]) async {
    latestLinkInventory = links
    await sendLinkInventoryToCurrent()
  }

  /// Sends the latest inventory on the current control connection. A no-op
  /// without a connection or before the peer signals the capability.
  private func sendLinkInventoryToCurrent() async {
    guard peerSupportsLinkInventory, let connection else {
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

  /// Sends this host's measured public address on the current control connection.
  /// Used by the path-change, routing, and periodic refresh triggers. A no-op when
  /// no iPhone is connected.
  func sendPublicAddressToCurrent(_ addresses: AddressPair) async {
    guard let connection else {
      return
    }
    await sendPublicAddress(addresses, on: connection)
  }

  /// Sends this host's measured public address on a specific control connection,
  /// so a freshly accepted connection carries it as part of its own handshake.
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

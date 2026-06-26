//
//  PhoneControlClient.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let statusPushIntervalSeconds: UInt64 = 5

// MARK: - PhoneControlClient

/// Runs the iPhone side of the control link by dialing the Mac. It browses for
/// the Mac control Bonjour service over the local link, connects to it, receives
/// the WireGuard server endpoint, applies it through `onSetServerEndpoint`,
/// acknowledges, and pushes periodic status snapshots back to the Mac. The Mac
/// hosts the listener; this dials out, which an iOS packet-tunnel extension is
/// permitted to do.
@MainActor
final class PhoneControlClient {
  typealias EndpointHandler = @MainActor (RelayEndpoint) -> Void
  typealias StatusProvider = @MainActor () -> RelayControlMessage.Status

  let queue = DispatchQueue(label: "io.goodkind.celltunnel.controlClient")
  private var browser: NWBrowser?
  private var connection: NWConnection?
  private var statusTimer: DispatchSourceTimer?
  var redialTimer: DispatchSourceTimer?
  var isActive = false
  // The agent control service name the phone connected to (the Mac hostname),
  // reported as the peer name. Cleared when the link drops.
  private var peerServiceName: String?
  // The dialable endpoint for each discovered service id, so a selection resolves
  // to the endpoint to dial without re-browsing.
  private var serviceEndpoints: [String: NWEndpoint] = [:]
  // The service id the user (or the single-peer auto-select) chose to dial.
  private var selectedServiceID: String?
  // The service id of the live connection, so a selection change to a different
  // peer drops the old link before dialing the new one.
  private var connectedServiceID: String?

  var onSetServerEndpoint: EndpointHandler?
  var statusProvider: StatusProvider?
  // Fired when the control connection drops, which is the reliable signal that
  // the agent died or restarted. The data plane dials over UDP and does not
  // surface a drop, so the provider uses this to reset the stale data link.
  var onConnectionDropped: (@MainActor () -> Void)?
  /// Fired with the agent's confirmed route state, so the status path reports
  /// installed routes from the agent's truth rather than the local routing intent.
  var onRouteState: (@MainActor (Bool) -> Void)?
  /// Fired with the agent's persisted routing intent, the value behind the Route
  /// traffic switch, so the phone mirrors the agent's truth rather than holding
  /// its own copy. The agent re-sends it on every connection handshake.
  var onRoutingIntent: (@MainActor (Bool) -> Void)?
  /// Fired with the connected peer's name, the agent control service the phone
  /// dialed (the Mac hostname), or `nil` when the link drops. The displayed peer
  /// name comes from here.
  var onPeerName: (@MainActor (String?) -> Void)?
  /// Fired with the peer's measured public address received over the control link,
  /// shown as the peer's public IP.
  var onPeerPublicAddress: (@MainActor (AddressPair) -> Void)?
  /// Fired with the agent's relay-link candidates received over the control
  /// link, shown on the peer `Available Interfaces` row.
  var onPeerAvailableLinks: (@MainActor ([RelayLinkSummary]) -> Void)?
  /// Fired with the agent's current relay-session id, minted on each control
  /// promotion, so the forwarder stamps it on every relay prime and the agent
  /// admits this phone's links.
  var onRelaySession: (@MainActor (UInt64) -> Void)?
  /// Fired when the control connection reaches ready, so the public-address
  /// exchange sends this device's address over a link that now exists. The data
  /// link comes up on its own timeline, so the send is driven by the control link
  /// becoming ready rather than the data peer going live.
  var onConnectionReady: (@MainActor () -> Void)?
  /// Fired with the Mac agent control services the browser currently sees, each a
  /// selectable peer. The engine stores them for the served snapshot and decides
  /// which one to dial.
  var onServicesChanged: (@MainActor ([TunnelRelayService]) -> Void)?

  // MARK: - Lifecycle

  func start() {
    stop()
    isActive = true
    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    let descriptor = NWBrowser.Descriptor.bonjour(
      type: relayControlServiceType,
      domain: nil
    )
    let nwBrowser = NWBrowser(for: descriptor, using: parameters)
    nwBrowser.stateUpdateHandler = { [weak self] state in
      Task { @MainActor [weak self] in
        self?.handle(browserState: state)
      }
    }
    nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
      let endpoints = results.map(\.endpoint)
      Task { @MainActor [weak self] in
        self?.applyBrowseResults(endpoints)
      }
    }
    nwBrowser.start(queue: queue)
    browser = nwBrowser
    logger.notice(
      "control client browsing service=\(relayControlServiceType, privacy: .public)"
    )
  }

  func stop() {
    isActive = false
    redialTimer?.cancel()
    redialTimer = nil
    statusTimer?.cancel()
    statusTimer = nil
    connection?.cancel()
    connection = nil
    connectedServiceID = nil
    browser?.cancel()
    browser = nil
    logger.notice("control client stopped")
  }

  // MARK: - Browse and dial

  private func handle(browserState state: NWBrowser.State) {
    switch state {
    case .ready:
      logger.notice("control client browser ready")
    case .failed(let error):
      logger.error(
        "control client browser failed error=\(error.localizedDescription, privacy: .public)"
      )
      scheduleReconnect()
    default:
      logger.debug("control client browser state changed")
    }
  }

  // Maps the browse results to selectable services, surfaces them, and dials the
  // resolved target. The user's selection wins when its service is still present;
  // otherwise a single discovered peer is auto-selected and dialed, matching the
  // agent's single-peer behavior. With several peers and no selection, nothing is
  // dialed until the user picks one.
  private func applyBrowseResults(_ endpoints: [NWEndpoint]) {
    var services: [TunnelRelayService] = []
    var endpointsByID: [String: NWEndpoint] = [:]
    for endpoint in endpoints {
      guard case let .service(name, type, domain, interface) = endpoint else {
        continue
      }
      let interfaceIndex = interface.map { Int($0.index) } ?? 0
      let identifier = "\(name).\(type).\(domain)#\(interfaceIndex)"
      endpointsByID[identifier] = endpoint
      services.append(
        TunnelRelayService(
          id: identifier,
          serviceName: name,
          serviceType: type,
          domain: domain,
          interfaceIndex: interfaceIndex,
          hostName: "",
          endpoints: [],
          preferredEndpoint: nil,
          isSelected: identifier == selectedServiceID
        )
      )
    }
    serviceEndpoints = endpointsByID
    onServicesChanged?(services)
    redialSelectedIfNeeded()
  }

  // Redials the standing selection after a browse refresh, so a peer that dropped
  // and reappeared reconnects without the user reselecting. The engine owns the
  // initial selection decision; this only re-establishes an existing choice.
  private func redialSelectedIfNeeded() {
    guard let selectedServiceID, connection == nil,
      let endpoint = serviceEndpoints[selectedServiceID]
    else {
      return
    }
    connectIfNeeded(to: endpoint, id: selectedServiceID)
  }

  /// Records the user's chosen service and dials it, dropping a live connection to a
  /// different peer first, so selection drives which Mac the iPhone joins.
  func selectService(id: String) {
    selectedServiceID = id
    guard let endpoint = serviceEndpoints[id] else {
      logger.notice(
        "control client selection deferred id=\(id, privacy: .public) reason=not-yet-discovered"
      )
      return
    }
    if connectedServiceID == id, connection != nil {
      return
    }
    if connection != nil {
      connection?.cancel()
      connection = nil
      connectedServiceID = nil
    }
    connectIfNeeded(to: endpoint, id: id)
    logger.notice("control client dialing selected peer id=\(id, privacy: .public)")
  }

  private func connectIfNeeded(to endpoint: NWEndpoint, id: String) {
    guard connection == nil else {
      return
    }
    connectedServiceID = id
    if case .service(let name, _, _, _) = endpoint {
      peerServiceName = name
    }
    let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true
    let framerOptions = RelayControlFramerSupport.framerOptions()
    parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

    let nwConnection = NWConnection(to: endpoint, using: parameters)
    connection = nwConnection
    nwConnection.stateUpdateHandler = { [weak self, weak nwConnection] state in
      Task { @MainActor [weak self, weak nwConnection] in
        guard let nwConnection else {
          return
        }
        self?.handle(connectionState: state, connection: nwConnection)
      }
    }
    nwConnection.start(queue: queue)
    logger.notice(
      "control client dialing endpoint=\(String(describing: endpoint), privacy: .public)"
    )
  }

  private func handle(connectionState state: NWConnection.State, connection: NWConnection) {
    switch state {
    case .ready:
      logger.notice(
        "control client connection ready peer=\(self.peerServiceName ?? "unknown", privacy: .public)"
      )
      onPeerName?(peerServiceName)
      receive(on: connection)
      sendStatusSnapshot(on: connection)
      startStatusLoop()
      onConnectionReady?()
    case .waiting(let error):
      logger.error(
        "control client connection waiting error=\(error.localizedDescription, privacy: .public)"
      )
    case .failed(let error):
      logger.error(
        "control client connection failed error=\(error.localizedDescription, privacy: .public)"
      )
      if self.connection === connection {
        self.connection = nil
      }
      connection.cancel()
      notifyConnectionDropped()
      scheduleReconnect()
    case .cancelled:
      if self.connection === connection {
        self.connection = nil
        logger.notice("control client connection cancelled")
      }
      notifyConnectionDropped()
      scheduleReconnect()
    default:
      break
    }
  }

  // Tells the provider the control link dropped so it can reset the stale data
  // link. Gated on `isActive` so an intentional `stop` does not trigger it.
  private func notifyConnectionDropped() {
    peerServiceName = nil
    connectedServiceID = nil
    guard isActive else {
      return
    }
    onPeerName?(nil)
    onConnectionDropped?()
  }

  // MARK: - Receive and decode

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] data, _, _, error in
      if let error {
        logger.error(
          "control client receive failed error=\(error.localizedDescription, privacy: .public)"
        )
        Task { @MainActor [weak self, weak connection] in
          guard let connection else {
            return
          }
          if self?.connection === connection {
            self?.connection = nil
          }
          connection.cancel()
        }
        return
      }

      if let data, !data.isEmpty {
        Task { @MainActor [weak self, weak connection] in
          guard let connection else {
            return
          }
          self?.handlePayload(data, connection: connection)
        }
      }

      // Re-arm for the next framed message regardless of `isComplete`: the
      // framer marks each control message complete, but the stream stays open
      // for later messages such as the agent's route-state confirmation. The
      // agent's own receive loop re-arms the same way.
      guard let connection else {
        return
      }

      Task { @MainActor [weak self, weak connection] in
        guard let connection else {
          return
        }
        self?.receive(on: connection)
      }
    }
  }

  private func handlePayload(_ payload: Data, connection: NWConnection) {
    let decoded: RelayControlMessage
    do {
      decoded = try RelayControlMessageCodec.decode(payload)
    } catch let RelayControlCodecError.unsupportedVersion(version) {
      logger.error(
        "control message rejected unsupportedVersion=\(version, privacy: .public)"
      )
      let failure = RelayControlMessage.Failure(
        code: "unsupported-version",
        message: "iPhone supports control wire version \(relayControlWireVersion)"
      )
      send(.error(failure), on: connection)
      return
    } catch {
      logger.error(
        "control message decode failed error=\(error.localizedDescription, privacy: .public)"
      )
      let failure = RelayControlMessage.Failure(
        code: "decode-failure",
        message: error.localizedDescription
      )
      send(.error(failure), on: connection)
      return
    }

    dispatch(decoded, on: connection)
  }
}

// MARK: - Dispatch and send

extension PhoneControlClient {
  private func dispatch(_ decoded: RelayControlMessage, on connection: NWConnection) {
    switch decoded {
    case .setServerEndpoint(let payload):
      logger.notice(
        """
        control received set-server-endpoint host=\(payload.endpoint.host, privacy: .public) \
        port=\(payload.endpoint.port, privacy: .public) \
        family=\(payload.endpoint.addressFamily.rawValue, privacy: .public)
        """
      )
      onSetServerEndpoint?(payload.endpoint)
      let ack = RelayControlMessage.Acknowledge(
        requestKind: "set-server-endpoint",
        detail: "endpoint accepted"
      )
      send(.acknowledge(ack), on: connection)
      sendStatusSnapshot(on: connection)
    case .acknowledge:
      logger.debug("control received unexpected acknowledge from peer")
    case .status:
      logger.debug("control received unexpected status from peer")
    case .error(let payload):
      logger.error(
        """
        control received error from peer code=\(payload.code, privacy: .public) \
        message=\(payload.message, privacy: .public)
        """
      )
    case .linkInventory(let payload):
      logger.notice(
        "control received link-inventory count=\(payload.links.count, privacy: .public)"
      )
      onPeerAvailableLinks?(payload.links)
    case .setRoutingEnabled:
      logger.debug("control received unexpected set-routing-enabled from peer")
    case .routeState(let payload):
      logger.notice(
        "control received route-state installed=\(payload.installed, privacy: .public)"
      )
      onRouteState?(payload.installed)
    case .routingIntent(let payload):
      logger.notice(
        "control received routing-intent enabled=\(payload.enabled, privacy: .public)"
      )
      onRoutingIntent?(payload.enabled)
    case .publicAddress(let payload):
      logger.notice(
        """
        control received peer public address \
        ipv4=\(payload.addresses.ipv4 ?? "none", privacy: .public) \
        ipv6=\(payload.addresses.ipv6 ?? "none", privacy: .public)
        """
      )
      onPeerPublicAddress?(payload.addresses)
    case .relaySession(let payload):
      logger.notice("control received relay-session")
      onRelaySession?(payload.sessionID)
    }
  }

  /// Pushes the user's routing choice to the agent over the control link. Without
  /// a live control connection the choice is dropped, since the agent learns the
  /// current choice again when the link re-establishes and the app re-sends.
  func sendRoutingEnabled(_ enabled: Bool) {
    guard let connection else {
      logger.notice("control client routing change dropped: no control connection")
      return
    }
    let message = RelayControlMessage.setRoutingEnabled(
      RelayControlMessage.SetRoutingEnabled(enabled: enabled))
    send(message, on: connection)
    logger.notice("control client sent routing enabled=\(enabled, privacy: .public)")
  }

  /// Sends this device's measured public address to the agent over the control
  /// link. Dropped without a live connection; the exchange re-sends when the link
  /// re-establishes and the peer reconnects.
  func sendPublicAddress(_ addresses: AddressPair) {
    guard let connection else {
      logger.notice("control client public address dropped: no control connection")
      return
    }
    let message = RelayControlMessage.publicAddress(
      RelayControlMessage.PublicAddress(addresses: addresses))
    send(message, on: connection)
    logger.notice(
      """
      control client sent public address \
      ipv4=\(addresses.ipv4 ?? "none", privacy: .public) \
      ipv6=\(addresses.ipv6 ?? "none", privacy: .public)
      """
    )
  }

  private func send(_ message: RelayControlMessage, on connection: NWConnection) {
    let payload: Data
    do {
      payload = try RelayControlMessageCodec.encode(message)
    } catch {
      logger.error(
        """
        control encode failed kind=\(message.kindLabel, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public)
        """
      )
      return
    }
    let framerMessage = NWProtocolFramer.Message(definition: RelayControlFramer.definition)
    let context = NWConnection.ContentContext(
      identifier: message.kindLabel,
      metadata: [framerMessage]
    )
    connection.send(
      content: payload,
      contentContext: context,
      isComplete: true,
      completion: .contentProcessed { error in
        guard let error else {
          return
        }
        logger.error(
          """
          control send failed kind=\(message.kindLabel, privacy: .public) \
          error=\(error.localizedDescription, privacy: .public)
          """
        )
      }
    )
  }

  private func sendStatusSnapshot(on connection: NWConnection) {
    let status: RelayControlMessage.Status
    if let provider = statusProvider {
      status = provider()
    } else {
      status = RelayControlMessage.Status(hasCellularPath: false)
    }
    logger.debug(
      "control status push hasCellularPath=\(status.hasCellularPath, privacy: .public)"
    )
    send(.status(status), on: connection)
  }

}

// MARK: - Status push loop

extension PhoneControlClient {
  // A repeating dispatch timer fires the periodic status push instead of a
  // sleep loop, satisfying the sleep_in_production rule. The handler is
  // `@Sendable` so it stays nonisolated and runs on the client queue; without
  // it the closure inherits MainActor isolation and dispatch firing it off the
  // main thread traps. It hops to the MainActor through a Task for the
  // connection and status-provider access.
  func startStatusLoop() {
    statusTimer?.cancel()
    logger.notice(
      "control status loop starting intervalSeconds=\(statusPushIntervalSeconds, privacy: .public)"
    )
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .seconds(Int(statusPushIntervalSeconds)),
      repeating: .seconds(Int(statusPushIntervalSeconds))
    )
    timer.setEventHandler { @Sendable [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let connection else {
          return
        }
        sendStatusSnapshot(on: connection)
      }
    }
    timer.resume()
    statusTimer = timer
  }
}

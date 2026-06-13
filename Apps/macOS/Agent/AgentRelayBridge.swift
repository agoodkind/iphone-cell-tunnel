//
//  AgentRelayBridge.swift
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
private let relayDataServiceType = "_cellrelay._udp"
/// Seconds between reaper ticks that age each phone link toward removal.
private let reaperIntervalSeconds = 2
/// Consecutive reaper ticks with no inbound datagram before a phone link is
/// reaped. Set above the iPhone's stale limit so the iPhone re-dials a dead link
/// (replacing it here) before the reaper removes it, leaving the reaper to clear
/// only links the iPhone abandoned. At the 2s interval this is a ~8s window.
private let reaperTickLimit = 4

// MARK: - AgentPhoneLink

/// One open link from the iPhone, keyed by the Mac-facing interface it arrived
/// on. The agent keeps one per interface at once so a loss of the carrying link
/// moves traffic to another already-open link. A link is removed only when its
/// connection errors.
struct AgentPhoneLink {
  let interfaceName: String
  let linkClass: RelayLinkClass
  let connection: NWConnection
  /// The relay-session id the admitting prime carried, so a session rotation can
  /// drop the links that belong to a prior promoted peer.
  let sessionID: UInt64
  /// Reaper ticks elapsed since the last datagram arrived on this link. Reset to
  /// zero on every inbound datagram and incremented once per reaper tick; a link
  /// past the reap limit is dropped because a UDP connection never reports that
  /// the iPhone went away.
  var ticksSinceActivity: Int = 0
}

// MARK: - AgentRelayBridge

/// Hosts the relay data plane in the agent, a normal process that receives
/// inbound from both peers over UDP. One listener binds the relay data port and
/// advertises the relay Bonjour service on every path, so the iPhone reaches it
/// over the wired USB link, Wi-Fi LAN, and AWDL at once. The Mac tunnel extension
/// dials it over loopback; the iPhone extension dials it once per interface, so
/// the bridge holds one Mac connection and a set of phone links keyed by
/// interface. Each datagram from the Mac goes out the carrying phone link the
/// chooser selects; each datagram from any phone link goes to the Mac. Each send
/// stays an independent UDP datagram with no added ordering or reliability;
/// WireGuard owns end-to-end integrity and dedupes any duplicate.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects start with `queue`, so their callbacks
/// fire on `queue`.
final class AgentRelayBridge: @unchecked Sendable {
  let queue = DispatchQueue(label: "io.goodkind.celltunnel.agent.relay")
  private var listener: NWListener?
  // The Mac tunnel-extension loopback connection. Read by the receive extension's
  // forward path, so it is internal rather than private.
  var macConnection: NWConnection?

  // The open phone links keyed by Mac-facing interface name, the cached carrying
  // pointer the upload path reads per datagram, and the interface it points at.
  // All touched only on `queue`.
  var phoneLinks: [String: AgentPhoneLink] = [:]
  var egressConnection: NWConnection?
  var egressInterfaceName: String?
  var reaperTimer: DispatchSourceTimer?
  var didLogHeartbeatEcho = false
  var didLogPhoneReceiveError = false
  var didLogForeignSession = false
  var didLogPhoneReceive = false
  /// The relay-session id the control listener last minted on promotion. A phone
  /// connection is admitted only when its prime carries this value, so the data
  /// plane serves only the promoted control peer. `nil` before the first control
  /// connection is promoted, when no relay link may be admitted.
  var currentSessionID: UInt64?

  /// Fired when the first phone link goes live and when the last one drops, so
  /// the agent tells the Mac extension to install or withdraw routes with the
  /// link set. Route gating is any-link-up: routes install on the 0-to-one
  /// transition and withdraw on the one-to-0 transition.
  var onPhoneConnected: (@Sendable () -> Void)?
  var onPhoneDisconnected: (@Sendable () -> Void)?
  /// Fired whenever the carrying link changes, with its interface identifier, its
  /// transport class, and the local and peer addresses of the carrying connection,
  /// so the agent reports the same `Connection` rows the iPhone does. Both address
  /// pairs come from the same connection's path endpoints.
  var onEgressInterfaceChange:
    (@Sendable (String?, RelayLinkClass?, AddressPair, AddressPair) -> Void)?
  /// Fired off the datagram path whenever the set of open phone links changes,
  /// with the lean summaries sorted best first, so the agent reports this
  /// side's `Available Interfaces` row and pushes the list to the iPhone.
  var onAvailableLinksChange: (@Sendable ([RelayLinkSummary]) -> Void)?
  /// The last reported summary set, compared on each egress recompute so the
  /// callback fires only on a real change. Touched only on `queue`.
  var lastReportedAvailableLinks: [RelayLinkSummary] = []
  /// Fired with the full adopted-link set whenever it changes, so the status
  /// snapshot lists every warm link, not only the carrying one.
  var onLinkSetChange: (@Sendable ([AgentLinkStatus]) -> Void)?

  // MARK: - Lifecycle

  func start(serviceName: String) {
    queue.async { [weak self] in
      self?.startOnQueue(serviceName: serviceName)
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.stopOnQueue()
    }
  }

  /// Installs the relay-session id minted when the control listener promoted a
  /// connection. The bridge admits new links only from primes carrying this id,
  /// and immediately drops links stamped with a prior id, so a new promotion (a
  /// reconnect or a switch to a different peer) rebinds the data plane to the
  /// peer just promoted with no overlap.
  func updateSessionID(_ sessionID: UInt64) {
    queue.async { [weak self] in
      self?.applySessionID(sessionID)
    }
  }

  /// Clears the admit session and drops every phone link, so the data plane goes idle
  /// when no iPhone is selected for egress. Called when the selected control
  /// connection ends, so a deselected iPhone's relay primes are rejected as
  /// foreign-session until the Mac selects an iPhone again.
  func clearSession() {
    queue.async { [weak self] in
      self?.clearSessionOnQueue()
    }
  }

  private func clearSessionOnQueue() {
    currentSessionID = nil
    let connections = phoneLinks.values.map(\.connection)
    for connection in connections {
      connection.cancel()
      removePhoneLink(for: connection, reason: "selection-cleared")
    }
    logger.notice(
      "agent relay bridge session cleared dropped=\(connections.count, privacy: .public)"
    )
  }

  private func applySessionID(_ sessionID: UInt64) {
    guard currentSessionID != sessionID else {
      return
    }
    currentSessionID = sessionID
    let stale = phoneLinks.values.filter { $0.sessionID != sessionID }
    for link in stale {
      link.connection.cancel()
      removePhoneLink(for: link.connection, reason: "session-rotated")
    }
    logger.notice(
      "agent relay bridge session updated dropped=\(stale.count, privacy: .public)"
    )
  }

  private func startOnQueue(serviceName: String) {
    let port = resolvedRelayListenerPort()
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    // Advertise on every path, wired and peer-to-peer, so the relay service is
    // reachable over the USB link, Wi-Fi LAN, and AWDL. The iPhone dials one
    // link per interface; the agent keeps them all warm.
    parameters.includePeerToPeer = true

    let nwListener: NWListener
    do {
      nwListener = try NWListener(using: parameters, on: port)
    } catch {
      logger.error(
        """
        agent relay bridge listener create failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=skip-bridge
        """
      )
      return
    }
    nwListener.service = NWListener.Service(name: serviceName, type: relayDataServiceType)
    nwListener.stateUpdateHandler = { state in
      applyRelayListenerState(state)
    }
    nwListener.newConnectionHandler = { [weak self] connection in
      self?.adopt(connection)
    }
    nwListener.start(queue: queue)
    listener = nwListener
    startReaper()
    logger.notice(
      """
      agent relay bridge starting service=\(relayDataServiceType, privacy: .public) \
      name=\(serviceName, privacy: .public) port=\(port.rawValue ?? 0, privacy: .public)
      """
    )
  }

  private func stopOnQueue() {
    stopReaper()
    macConnection?.cancel()
    macConnection = nil
    for link in phoneLinks.values {
      link.connection.cancel()
    }
    let hadReportedAvailableLinks = !lastReportedAvailableLinks.isEmpty
    phoneLinks.removeAll()
    lastReportedAvailableLinks = []
    egressConnection = nil
    egressInterfaceName = nil
    currentSessionID = nil
    didLogForeignSession = false
    if hadReportedAvailableLinks {
      onAvailableLinksChange?([])
    }
    listener?.cancel()
    listener = nil
    logger.notice("agent relay bridge stopped")
  }

  // MARK: - Connection adoption

  private func adopt(_ connection: NWConnection) {
    let isLoopback = Self.isLoopback(connection.endpoint)
    logger.notice(
      """
      agent relay bridge inbound connection \
      endpoint=\(String(describing: connection.endpoint), privacy: .public) \
      loopback=\(isLoopback, privacy: .public)
      """
    )
    if isLoopback {
      macConnection?.cancel()
      macConnection = connection
      logger.notice(
        """
        agent relay bridge adopted mac connection \
        endpoint=\(String(describing: connection.endpoint), privacy: .public)
        """
      )
    }
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let connection else {
        return
      }
      self?.handle(state: state, connection: connection, isLoopback: isLoopback)
    }
    connection.start(queue: queue)
    receive(on: connection, fromMac: isLoopback)
  }

  private func handle(state: NWConnection.State, connection: NWConnection, isLoopback: Bool) {
    switch state {
    case .failed(let error):
      logger.error(
        """
        agent relay bridge connection failed mac=\(isLoopback, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public)
        """
      )
      connection.cancel()
      clearIfCurrent(connection, isLoopback: isLoopback, reason: "state-failed")
    case .cancelled:
      clearIfCurrent(connection, isLoopback: isLoopback, reason: "state-cancelled")
    default:
      break
    }
  }

  func clearIfCurrent(_ connection: NWConnection, isLoopback: Bool, reason: String) {
    if isLoopback {
      if macConnection === connection {
        macConnection = nil
      }
    } else {
      removePhoneLink(for: connection, reason: reason)
    }
  }

  /// Starts the repeating reaper once the listener is up. It ages each phone link
  /// and drops one the iPhone has stopped servicing, since a UDP connection never
  /// reports that its peer went away. The timer runs on the relay queue.
  private func startReaper() {
    guard reaperTimer == nil else {
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .seconds(reaperIntervalSeconds),
      repeating: .seconds(reaperIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      self?.onReaperTick()
    }
    timer.resume()
    reaperTimer = timer
    logger.notice("agent relay bridge reaper started")
  }

  private func stopReaper() {
    reaperTimer?.cancel()
    reaperTimer = nil
    logger.notice("agent relay bridge reaper stopped")
  }

  private func onReaperTick() {
    var staleConnections: [NWConnection] = []
    for (name, link) in phoneLinks {
      let ticks = link.ticksSinceActivity + 1
      phoneLinks[name]?.ticksSinceActivity = ticks
      if ticks >= reaperTickLimit {
        staleConnections.append(link.connection)
      }
    }
    for connection in staleConnections {
      logger.notice("agent relay bridge reaping silent phone link")
      connection.cancel()
      removePhoneLink(for: connection, reason: "reaped")
    }
  }

  // MARK: - Loopback classification

  private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else {
      return false
    }
    switch host {
    case .ipv4(let address):
      return address.isLoopback
    case .ipv6(let address):
      return address.isLoopback
    case .name(let name, _):
      return name == "localhost"
    @unknown default:
      return false
    }
  }
}

// MARK: - Listener state handling

/// Logs the relay bridge listener lifecycle so its bind and readiness are
/// visible in the log.
private func applyRelayListenerState(_ state: NWListener.State) {
  switch state {
  case .ready:
    logger.notice("agent relay bridge listener ready")
  case .failed(let error):
    logger.error(
      "agent relay bridge listener failed error=\(error.localizedDescription, privacy: .public)"
    )
  case .cancelled:
    logger.notice("agent relay bridge listener cancelled")
  default:
    break
  }
}

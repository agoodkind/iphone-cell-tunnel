//
//  PhoneRelayForwarder.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - PhoneMacLink

/// One open link to the Mac agent, keyed by the iPhone interface it runs over.
/// The forwarder keeps one per reachable interface at once, so a loss of the
/// carrying link moves traffic to another already-open link. `isReady` gates a
/// link out of the carrying set until its connection is up and primed.
struct PhoneMacLink {
  let interfaceName: String
  let linkClass: RelayLinkClass
  let connection: NWConnection
  var isReady: Bool
  /// Whether this link has sent its session prime, the datagram carrying the
  /// agent's current relay-session token. A link is a carrying candidate and a
  /// heartbeat target only once primed, so the iPhone never sends relay traffic
  /// on a link the agent would reject for lacking the session token.
  var isPrimed: Bool = false
  /// Heartbeat ticks elapsed since the last datagram arrived on this link. Reset
  /// to zero on every inbound datagram and incremented once per heartbeat tick;
  /// a link that crosses the stale limit is re-dialed because a UDP connection
  /// never reports that its peer went away.
  var ticksSinceInbound: Int = 0

  /// Whether the link may carry relay traffic: its connection is up and it has
  /// primed with the current session token.
  var isCarryable: Bool {
    isReady && isPrimed
  }
}

// MARK: - PhoneRelayForwarder

/// Owns the entire iPhone relay data plane on one serial queue: the set of warm
/// Mac-facing links keyed by interface, the cellular NWConnection to the
/// WireGuard server, the connecting/ready state machine with its pending buffer,
/// and the lock-free `RelayMetrics`. Every datagram in both directions is
/// received, wrapped, and forwarded on this one queue with no per-packet actor
/// hop, so throughput is not gated by the MainActor.
///
/// Multi-link: the probe reports which interfaces the agent is reachable on, the
/// forwarder dials one link per interface and keeps them all open, and the chooser
/// picks the carrying link the download path sends on (the override if set, else
/// the highest-scoring open link). A link closes only when its connection errors;
/// the carrying link is recomputed on each open or close, never on a timer. The
/// dial, prime, and carrying choice live in `PhoneRelayForwarder+Link.swift`; the
/// cellular and download halves live in `PhoneRelayForwarder+Cellular.swift`.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects and timers start with `queue`, so their
/// callbacks fire on `queue`, and the public API funnels through `queue.async`.
/// Lifecycle transitions are pushed to the MainActor UI through the `@Sendable`
/// callbacks; nothing on the per-packet path touches MainActor.
final class PhoneRelayForwarder: @unchecked Sendable {
  let metrics = RelayMetrics()

  let queue = DispatchQueue(label: "CellTunnelPhone.RelayPlane")

  // The host's network policy: pin each connection to its physical interface, or
  // leave it on the host network. Injected so the data plane never reads the
  // build target.
  let interfaceBinder: RelayInterfaceBinder

  // The open Mac-facing links keyed by iPhone interface name and the cached
  // carrying pointer the download path reads per datagram. `egressInterfaceName`
  // records which link is carrying so the chooser can keep it stable.
  // `preferredInterface` is the override a UI or a future algorithm sets to force
  // the carrying link; nil means use the score order. All touched only on `queue`.
  var macLinks: [String: PhoneMacLink] = [:]
  var egressConnection: NWConnection?
  var egressInterfaceName: String?
  var preferredInterface: String?
  var hasLivePeer = false

  // The most recent interface set the probe reported, kept so a stale link can be
  // re-dialed without waiting for the probe to re-emit. The heartbeat timer sends
  // an empty datagram on every ready link and re-dials any link gone silent.
  var lastKnownInterfaces: [String: RelayMacInterface] = [:]
  var heartbeatTimer: DispatchSourceTimer?
  // The agent's current relay-session id, received over the control link and
  // stamped on every link's prime. `nil` until the first control session is
  // established, when no link may prime and so none may carry.
  var currentSessionID: UInt64?

  var cellularConnection: NWConnection?
  var endpointFamily = RelayAddressFamily.ipv4
  var state = WireGuardDatagramRelayState.stopped
  var pendingDatagrams: [WireGuardDatagram] = []
  var configuredEndpoint: RelayEndpoint?

  // Bounds the datagrams handed to the cellular socket but not yet accepted, so
  // an upload faster than the cellular uplink cannot balloon the OS send buffer.
  // The window sizes the bound from the measured send-buffer wait to hold loaded
  // upload latency low; the counter is the datagrams currently in flight against
  // it. Both are read and written only on `queue`, so neither needs an atomic.
  var cellularSendWindow = CellularSendWindow()
  var outstandingCellularSends = 0
  var loggedSendAllowance = 0
  // Set when a datagram is dropped because the window was full, the signal that
  // the window is the bottleneck and may grow. Read and cleared on the next
  // accepted send so the window grows only while the relay is filling it.
  var cellularWindowSaturated = false

  // Once-only flags so each boundary function logs context exactly once
  // (satisfying the boundary-log audit) instead of logging per datagram.
  let didLogMacReceive = Atomic<Bool>(false)
  let didLogMacSend = Atomic<Bool>(false)
  let didLogCellularReceive = Atomic<Bool>(false)
  let didLogCellularSend = Atomic<Bool>(false)
  let didLogHeartbeat = Atomic<Bool>(false)
  let didLogReceiveErrorTolerated = Atomic<Bool>(false)

  var onStateChange: (@Sendable (WireGuardDatagramRelayState) -> Void)?
  var onError: (@Sendable (String) -> Void)?
  /// Fired with whether a live Mac data link exists. It carries the liveness; the
  /// displayed peer name comes from the control service.
  var onPeerChange: (@Sendable (Bool) -> Void)?
  /// Fired whenever the carrying link changes, with its interface identifier, its
  /// transport class, and the local and peer addresses of the carrying connection.
  /// Both address pairs come from the same connection's path endpoints, so the
  /// `Connection` rows describe one connection rather than mixing an interface
  /// address with an endpoint address.
  var onEgressInterfaceChange:
    (@Sendable (String?, RelayLinkClass?, AddressPair, AddressPair) -> Void)?
  /// Fired off the packet path whenever the set of ready mac-facing links
  /// changes, with the lean summaries sorted best first, so the runtime
  /// reports this side's `Available Interfaces` row and carries the list in
  /// its status pushes.
  var onAvailableLinksChange: (@Sendable ([RelayLinkSummary]) -> Void)?
  /// The last reported summary set, compared on each egress recompute so the
  /// callback fires only on a real change. Touched only on `queue`.
  var lastReportedAvailableLinks: [RelayLinkSummary] = []

  // MARK: - Initialization

  init(interfaceBinder: RelayInterfaceBinder) {
    self.interfaceBinder = interfaceBinder
  }

  // MARK: - Public API (MainActor callers funnel onto the relay queue)

  func start() {
    logger.notice("phone relay forwarder ready, awaiting discovery")
  }

  func setServerEndpoint(_ endpoint: RelayEndpoint) {
    logger.notice(
      """
      phone relay forwarder server endpoint host=\(endpoint.host, privacy: .public) \
      port=\(endpoint.port, privacy: .public)
      """
    )
    queue.async { [weak self] in
      self?.applyEndpointOnQueue(endpoint)
    }
  }

  /// Receives the current set of reachable Mac interfaces from the probe and
  /// keeps the link set in step: dial any new interface, drop any that vanished.
  func reconcileLinks(_ interfaces: [RelayMacInterface]) {
    queue.async { [weak self] in
      self?.reconcileOnQueue(interfaces)
    }
  }

  /// Drops every link so they re-establish from the next discovery. The provider
  /// calls this when the control plane reports the agent died or restarted,
  /// because a UDP data link does not surface that drop on its own.
  func resetLinks() {
    queue.async { [weak self] in
      self?.resetLinksOnQueue()
    }
  }

  /// Stores the agent's current relay-session id and primes every ready link with
  /// it, so links brought up before the control session existed become carryable
  /// and a rotated id re-primes the links under the new value. The agent admits a
  /// link only from a prime carrying this id.
  func updateSessionID(_ sessionID: UInt64) {
    queue.async { [weak self] in
      self?.applySessionIDOnQueue(sessionID)
    }
  }

  func stop() {
    logger.notice("phone relay forwarder stop requested")
    queue.async { [weak self] in
      self?.stopOnQueue()
    }
  }

  // MARK: - Upload hot path (Mac -> server), queue-only, no actor hop

  /// Receives upload datagrams on one Mac link. Every link runs its own loop, so
  /// the iPhone forwards the Mac's upload no matter which link the agent egresses
  /// on. A heartbeat-sized datagram is the agent's echo: it refreshes the link's
  /// liveness and is never forwarded to the server.
  func receiveFromMac(on connection: NWConnection, interfaceName: String) {
    if didLogMacReceive.compareExchange(
      expected: false, desired: true, ordering: .relaxed
    ).exchanged {
      logger.notice("phone relay mac receive loop armed")
    }
    connection.receiveMessage { [weak self, weak connection] data, _, _, error in
      guard let self, let connection else {
        return
      }
      guard isCurrentLink(connection, interfaceName: interfaceName) else {
        return
      }
      if let error {
        handleLinkReceiveError(error, connection: connection, interfaceName: interfaceName)
        return
      }
      // Any datagram, heartbeat echo or real data, proves the link is alive, so
      // reset its staleness counter. Only real traffic is forwarded.
      macLinks[interfaceName]?.ticksSinceInbound = 0
      if let data, !data.isEmpty, !RelayHeartbeat.isHeartbeat(data) {
        metrics.addBytesIn(UInt64(data.count))
        metrics.addDatagramsFromMac()
        sendToServer(data)
      }
      receiveFromMac(on: connection, interfaceName: interfaceName)
    }
  }

  private func sendToServer(_ data: Data) {
    do {
      let datagram = try WireGuardDatagram(data: data, addressFamily: .ipv4)
      if state == .connecting {
        bufferPendingDatagram(datagram)
        return
      }
      guard state == .ready else {
        metrics.addDropped()
        logger.error(
          "phone relay send rejected state=\(self.state.rawValue, privacy: .public)"
        )
        return
      }
      cellularSend(datagram)
    } catch {
      metrics.addDropped()
      logger.error(
        "phone relay datagram from mac rejected error=\(error.localizedDescription, privacy: .public)"
      )
    }
  }
}

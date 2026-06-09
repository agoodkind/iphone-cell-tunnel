//
//  PhoneRelayForwarder+Link.swift
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
/// Seconds between heartbeats sent on every ready link. Short enough that the
/// agent keeps each link adopted and a dead link is noticed quickly, long enough
/// to stay negligible against relay traffic.
private let heartbeatIntervalSeconds = 2
/// Consecutive heartbeat ticks with no inbound datagram before a link is treated
/// as dead and re-dialed. At the 2s interval this is a ~6s liveness window.
private let staleLinkTickLimit = 3

// MARK: - Mac-facing links: dial, prime, carry

/// Keeps one open link per discovered interface and chooses which one carries.
/// The probe reports the interface set; this surface dials each new interface
/// pinned to it and primes it once so the agent adopts it. A link is closed only
/// when its connection errors; a browse that stops listing an interface does not
/// close its link. The carrying link is the chooser's pick, recomputed on each
/// open or close, never on a timer. Every method runs only on
/// `PhoneRelayForwarder.queue`.
extension PhoneRelayForwarder {
  // MARK: - Reconcile (prune to the live set, then dial any missing)

  /// Takes the probe's latest interface set as the source of truth. It replaces
  /// `lastKnownInterfaces` with exactly that set, so an interface that left the
  /// probe is pruned and never re-dialed, then dials any present interface that
  /// has no link. The probe fires only on a set change, so the heartbeat carries
  /// the same missing-link dial for a link that dies while its interface stays.
  func reconcileOnQueue(_ interfaces: [RelayMacInterface]) {
    let pairs = interfaces.map { interface in (interface.interfaceName, interface) }
    lastKnownInterfaces = Dictionary(pairs) { _, latest in latest }
    redialMissingLinks()
    startHeartbeatIfNeeded()
    recomputeEgress()
  }

  func resetLinksOnQueue() {
    guard !macLinks.isEmpty else {
      return
    }
    logger.notice("phone relay resetting all links on control drop")
    for link in macLinks.values {
      link.connection.cancel()
    }
    macLinks.removeAll()
    egressConnection = nil
    egressInterfaceName = nil
    recomputeEgress()
  }

  // MARK: - Dial (one link per interface)

  private func dialLink(_ interface: RelayMacInterface) {
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = interface.linkClass == .peerToPeer
    // The binder decides whether to pin this link to the discovered interface,
    // so each interface becomes its own link, or to leave it on the host
    // network when the agent is reachable there.
    interfaceBinder.configureLinkParameters(parameters, for: interface)
    let connection = NWConnection(to: interface.endpoint, using: parameters)
    macLinks[interface.interfaceName] = PhoneMacLink(
      interfaceName: interface.interfaceName,
      linkClass: interface.linkClass,
      connection: connection,
      isReady: false
    )
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let connection else {
        return
      }
      self?.handleLinkState(
        state, connection: connection, interfaceName: interface.interfaceName
      )
    }
    connection.start(queue: queue)
    logger.notice(
      """
      phone relay dialing link interface=\(interface.interfaceName, privacy: .public) \
      class=\(interface.linkClass.rawValue, privacy: .public) \
      endpoint=\(String(describing: interface.endpoint), privacy: .public)
      """
    )
  }

  private func handleLinkState(
    _ state: NWConnection.State, connection: NWConnection, interfaceName: String
  ) {
    guard isCurrentLink(connection, interfaceName: interfaceName) else {
      return
    }
    switch state {
    case .ready:
      macLinks[interfaceName]?.isReady = true
      logger.notice(
        "phone relay link ready interface=\(interfaceName, privacy: .public)"
      )
      primeLink(connection)
      receiveFromMac(on: connection, interfaceName: interfaceName)
      recomputeEgress()
    case .failed(let error):
      logger.error(
        """
        phone relay link failed interface=\(interfaceName, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public)
        """
      )
      removeLink(interfaceName: interfaceName, reason: "failed")
    case .cancelled:
      removeLink(interfaceName: interfaceName, reason: "cancelled")
    default:
      break
    }
  }

  /// Drops the link a failed send was bound to. A send error on the carrying
  /// link (no route to host when its interface goes away) is the reliable signal
  /// the path is gone, since the connection state may never reach .failed. The
  /// cellular download path calls this so the carrying choice moves at once.
  func failMacSend(on connection: NWConnection) {
    for (name, link) in macLinks where link.connection === connection {
      removeLink(interfaceName: name, reason: "send-error")
      return
    }
  }

  func handleLinkReceiveError(
    _ error: NWError, connection: NWConnection, interfaceName: String
  ) {
    logger.error(
      """
      phone relay link receive failed interface=\(interfaceName, privacy: .public) \
      error=\(error.localizedDescription, privacy: .public)
      """
    )
    connection.cancel()
    removeLink(interfaceName: interfaceName, reason: "receive-error")
  }

  // MARK: - Membership helpers

  func isCurrentLink(_ connection: NWConnection, interfaceName: String) -> Bool {
    macLinks[interfaceName]?.connection === connection
  }

  private func removeLink(interfaceName: String, reason: String) {
    guard let link = macLinks.removeValue(forKey: interfaceName) else {
      return
    }
    link.connection.cancel()
    logger.notice(
      """
      phone relay dropped link interface=\(interfaceName, privacy: .public) \
      reason=\(reason, privacy: .public) links=\(self.macLinks.count, privacy: .public)
      """
    )
    recomputeEgress()
  }

  // A UDP NWConnection has no peer until the first datagram is sent, so the
  // agent cannot learn the iPhone source endpoint to route replies. Send one
  // empty datagram so the agent adopts this connection as a link. The relay
  // forwards only non-empty datagrams, so the prime never reaches WireGuard.
  private func primeLink(_ connection: NWConnection) {
    let endpoint = connection.endpoint
    connection.send(
      content: Data(),
      completion: .contentProcessed { error in
        if let error {
          logger.error(
            "phone relay link prime failed error=\(error.localizedDescription, privacy: .public)"
          )
          return
        }
        logger.notice(
          "phone relay link prime sent endpoint=\(String(describing: endpoint), privacy: .public)"
        )
      }
    )
  }

  // MARK: - Carrying selection

  /// Recomputes the cached carrying pointer from the chooser off the packet path.
  /// The download path reads one pointer per datagram; it is recomputed here, on
  /// a link opening or closing or the override changing, never on a timer. Only
  /// ready links are carrying candidates.
  func recomputeEgress() {
    let openReady = macLinks.values
      .filter(\.isReady)
      .map { link in
        RelayLinkSnapshot(interfaceName: link.interfaceName, linkClass: link.linkClass)
      }
    let chosen = RelayLinkPolicy.chooseCarrying(
      preferred: preferredInterface, openLinks: Array(openReady)
    )
    let carryingConnection = chosen.flatMap { macLinks[$0]?.connection }
    if chosen != egressInterfaceName {
      let chosenClass = chosen.flatMap { macLinks[$0]?.linkClass }
      let localAddresses =
        carryingConnection?.currentPath?.localEndpoint?.addressPair ?? .empty
      let peerAddresses =
        carryingConnection?.currentPath?.remoteEndpoint?.addressPair ?? .empty
      logger.notice(
        "phone relay carrying link interface=\(chosen ?? "none", privacy: .public)"
      )
      onEgressInterfaceChange?(chosen, chosenClass, localAddresses, peerAddresses)
    }
    egressInterfaceName = chosen
    egressConnection = carryingConnection
    updatePeerState(hasEgress: egressConnection != nil)
  }

  private func updatePeerState(hasEgress: Bool) {
    guard hasEgress != hasLivePeer else {
      return
    }
    hasLivePeer = hasEgress
    onPeerChange?(hasEgress)
  }

  /// Sets the carrying-link interface override from the configuration, off the
  /// packet path. Nil restores score-order selection. The value originates in
  /// `RelayConfiguration`, the source of truth, not a literal here.
  func applyPreferredInterface(_ name: String?) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      preferredInterface = name
      logger.notice(
        "phone relay preferred interface set name=\(name ?? "none", privacy: .public)"
      )
      recomputeEgress()
    }
  }

  // MARK: - Heartbeat and liveness

  /// Starts the repeating heartbeat once the first link is dialed. The timer runs
  /// on the relay queue, so its handler reads and writes link state without a hop.
  func startHeartbeatIfNeeded() {
    guard heartbeatTimer == nil else {
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .seconds(heartbeatIntervalSeconds),
      repeating: .seconds(heartbeatIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      self?.onHeartbeatTick()
    }
    timer.resume()
    heartbeatTimer = timer
    logger.notice("phone relay heartbeat timer started")
  }

  /// Stops the heartbeat when the relay tears down.
  func stopHeartbeat() {
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
    logger.notice("phone relay heartbeat timer stopped")
  }

  /// Sends a heartbeat on every ready link and re-dials any link that has gone
  /// silent past the stale limit. The agent echoes each heartbeat, so a healthy
  /// link keeps resetting its counter while a dead link's counter climbs.
  private func onHeartbeatTick() {
    var staleNames: [String] = []
    for (name, link) in macLinks where link.isReady {
      sendHeartbeat(on: link.connection)
      let ticks = (macLinks[name]?.ticksSinceInbound ?? 0) + 1
      macLinks[name]?.ticksSinceInbound = ticks
      if ticks >= staleLinkTickLimit {
        staleNames.append(name)
      }
    }
    for name in staleNames {
      redialStaleLink(name)
    }
    redialMissingLinks()
  }

  private func redialStaleLink(_ name: String) {
    logger.notice(
      "phone relay re-dialing stale link interface=\(name, privacy: .public)"
    )
    removeLink(interfaceName: name, reason: "stale")
    if let interface = lastKnownInterfaces[name] {
      dialLink(interface)
    }
  }

  /// Dials any currently-known interface that has no link, so a link removed by
  /// error on a still-present interface is brought back within one heartbeat. The
  /// known set is pruned to the live interfaces in `reconcileOnQueue`, so a
  /// vanished interface is never in it and is never re-dialed. This is what keeps
  /// the link set from decaying to zero while a usable interface is present.
  private func redialMissingLinks() {
    let missing = RelayLinkHealth.interfacesNeedingRedial(
      known: Set(lastKnownInterfaces.keys), open: Set(macLinks.keys)
    )
    for name in missing {
      if let interface = lastKnownInterfaces[name] {
        dialLink(interface)
      }
    }
  }

  // Sends one empty datagram as a liveness heartbeat. The relay forwards only
  // non-empty datagrams, so a heartbeat never reaches WireGuard; the agent echoes
  // it so this side can tell the link is still alive.
  private func sendHeartbeat(on connection: NWConnection) {
    if didLogHeartbeat.compareExchange(
      expected: false, desired: true, ordering: .relaxed
    ).exchanged {
      logger.notice("phone relay heartbeat send path active")
    }
    connection.send(
      content: Data(),
      completion: .contentProcessed { error in
        if let error {
          logger.error(
            "phone relay heartbeat send failed error=\(error.localizedDescription, privacy: .public)"
          )
        }
      }
    )
  }
}

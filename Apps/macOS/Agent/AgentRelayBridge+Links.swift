//
//  AgentRelayBridge+Links.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Phone link set and carrying selection

/// The multi-link half of the relay bridge: the set of phone links and the
/// chooser that selects which one the upload path carries on. A link is admitted
/// on its first received datagram and removed only when its connection errors.
/// Every method runs only on `AgentRelayBridge.queue`.
extension AgentRelayBridge {
  // MARK: - Membership

  /// Adds or replaces the phone link for the interface a connection arrived on,
  /// stamped with the session token its admitting prime carried so a later
  /// session rotation can drop it. A redial on the same interface replaces the
  /// old connection. The first link installs routes; the carrying link is
  /// recomputed every time the set changes.
  func addPhoneLink(for connection: NWConnection, sessionID: UInt64) {
    let resolved = phoneInterface(for: connection)
    let wasEmpty = phoneLinks.isEmpty
    if let existing = phoneLinks[resolved.name], existing.connection !== connection {
      logger.notice(
        """
        agent relay bridge replacing link interface=\(resolved.name, privacy: .public) \
        cancelling previous connection
        """
      )
      existing.connection.cancel()
    }
    phoneLinks[resolved.name] = AgentPhoneLink(
      interfaceName: resolved.name,
      linkClass: resolved.linkClass,
      connection: connection,
      sessionID: sessionID
    )
    logger.notice(
      """
      agent relay bridge adopted phone link interface=\(resolved.name, privacy: .public) \
      class=\(resolved.linkClass.rawValue, privacy: .public) \
      links=\(self.phoneLinks.count, privacy: .public)
      """
    )
    recomputeEgress()
    if wasEmpty {
      onPhoneConnected?()
    }
  }

  /// Removes the phone link a cancelled or failed connection belonged to. The
  /// last link dropping withdraws routes.
  func removePhoneLink(for connection: NWConnection, reason: String) {
    guard let name = interfaceName(of: connection) else {
      return
    }
    phoneLinks.removeValue(forKey: name)
    logger.notice(
      """
      agent relay bridge dropped phone link interface=\(name, privacy: .public) \
      reason=\(reason, privacy: .public) links=\(self.phoneLinks.count, privacy: .public)
      """
    )
    recomputeEgress()
    if phoneLinks.isEmpty {
      onPhoneDisconnected?()
    }
  }

  /// Resets the reaper counter for the link a datagram arrived on, so an active
  /// link is never reaped. Called on every inbound phone datagram, after the link
  /// has been admitted by its session prime.
  func noteLinkActivity(on connection: NWConnection) {
    guard let name = interfaceName(of: connection) else {
      return
    }
    phoneLinks[name]?.ticksSinceActivity = 0
  }

  private func interfaceName(of connection: NWConnection) -> String? {
    for (name, link) in phoneLinks where link.connection === connection {
      return name
    }
    return nil
  }

  /// Whether a connection is still the live connection of an adopted link, so a
  /// tolerated receive error re-arms only a connection that still carries a link.
  func isAdoptedPhoneLink(_ connection: NWConnection) -> Bool {
    interfaceName(of: connection) != nil
  }

  // MARK: - Carrying selection

  /// Recomputes the cached carrying pointer from the chooser off the packet path.
  /// The upload path reads one pointer per datagram; it is recomputed here, on a
  /// link being admitted or removed. The agent has no override yet, so it uses
  /// the score order, the same order the iPhone uses, so both ends carry on the
  /// same link.
  func recomputeEgress() {
    let summaries = RelayLinkSummary.preferenceSorted(
      phoneLinks.map { name, link in
        RelayLinkSummary(interfaceName: name, linkClass: link.linkClass)
      }
    )
    if summaries != lastReportedAvailableLinks {
      lastReportedAvailableLinks = summaries
      onAvailableLinksChange?(summaries)
    }
    let openLinks = phoneLinks.values.map { link in
      RelayLinkSnapshot(interfaceName: link.interfaceName, linkClass: link.linkClass)
    }
    let chosen = RelayLinkPolicy.chooseCarrying(preferred: nil, openLinks: Array(openLinks))
    let carryingConnection = chosen.flatMap { phoneLinks[$0]?.connection }
    if chosen != egressInterfaceName {
      let chosenClass = chosen.flatMap { phoneLinks[$0]?.linkClass }
      let carryingPath = carryingConnection?.currentPath
      let localAddresses = carryingPath?.localEndpoint?.addressPair ?? .empty
      let peerAddresses = carryingPath?.remoteEndpoint?.addressPair ?? .empty
      logger.notice(
        "agent relay bridge carrying link interface=\(chosen ?? "none", privacy: .public)"
      )
      onEgressInterfaceChange?(chosen, chosenClass, localAddresses, peerAddresses)
    }
    egressInterfaceName = chosen
    egressConnection = carryingConnection
    publishLinkSet(carrying: chosen)
  }

  // Publishes the full adopted-link set whenever it changes, so the status
  // snapshot reports every warm link rather than only the carrying one. Sorted
  // by interface name for a stable rendering.
  private func publishLinkSet(carrying: String?) {
    let links = phoneLinks.values
      .map { link in
        AgentLinkStatus(
          interfaceName: link.interfaceName,
          linkClass: link.linkClass,
          isCarrying: link.interfaceName == carrying
        )
      }
      .sorted { lhs, rhs in
        lhs.interfaceName < rhs.interfaceName
      }
    onLinkSetChange?(links)
  }

  // MARK: - Interface derivation

  /// Resolves the Mac-facing interface and link class a connection runs over.
  /// The connection's path names the interface and its type; a link-local
  /// endpoint zone is the fallback when the path has no usable interface.
  private func phoneInterface(
    for connection: NWConnection
  ) -> (name: String, linkClass: RelayLinkClass) {
    if let interface = connection.currentPath?.availableInterfaces.first(where: { iface in
      iface.type != .loopback
    }) {
      return (interface.name, RelayLinkClass.forInterface(interface))
    }
    if let zone = Self.zoneName(from: connection.endpoint) {
      return (zone, RelayLinkClass.forInterfaceName(zone))
    }
    let fallback = String(describing: connection.endpoint)
    return (fallback, RelayLinkClass.forInterfaceName(fallback))
  }

  private static func zoneName(from endpoint: NWEndpoint) -> String? {
    guard case .hostPort(let host, _) = endpoint else {
      return nil
    }
    let description = "\(host)"
    guard let percent = description.firstIndex(of: "%") else {
      return nil
    }
    return String(description[description.index(after: percent)...])
  }
}

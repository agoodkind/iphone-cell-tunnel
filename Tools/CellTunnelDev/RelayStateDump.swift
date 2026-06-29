//
//  RelayStateDump.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import IP

// MARK: - Constants

private let relayStateLogger = CellTunnelLog.logger(category: .build)
/// The netstat routing-table columns this parser reads: the destination and the
/// interface, with the minimum column count a parsable row carries.
private let routeDestinationColumn = 0
private let routeInterfaceColumn = 3
private let routeMinimumColumns = 4

// MARK: - RelayStateDump

/// Renders the full debug view of the relay from one status snapshot: the live
/// routing intent, the reported and kernel route state, the control and tunnel
/// sections, and a final drift verdict. `relay-status` prints this after the
/// snapshot's own key=value lines, so one invocation shows everything and names any
/// pair that disagrees. Routing is no longer persisted, so there is no durable intent
/// to compare against the live one.
enum RelayStateDump {
  /// The assembled extra sections and whether any real drift was found.
  struct Rendering {
    let text: String
    let hasDrift: Bool
  }

  // MARK: - Rendering

  static func render(snapshot: TunnelDaemonStatusSnapshot) -> Rendering {
    var lines: [String] = []
    var driftPairs: [String] = []

    let live = snapshot.routingIntentEnabled
    lines.append("intent.live=\(live?.rawValue ?? "unknown")")

    let kernelRouteCount = kernelTunnelRouteCount(
      tunnelIPv4: snapshot.ipv4Address, tunnelIPv6: snapshot.ipv6Address
    )
    lines.append("routes.reported=\(snapshot.routeState.rawValue)")
    lines.append("routes.kernel=\(kernelRouteCount.map(String.init) ?? "unknown")")
    if let kernelRouteCount {
      let kernelInstalled = kernelRouteCount > 0
      let reportedInstalled = snapshot.routeState == .installed
      if kernelInstalled != reportedInstalled {
        driftPairs.append("routes.reported!=routes.kernel")
      }
    }

    lines.append("control.peer=\(snapshot.connectedPeerName ?? "none")")
    lines.append("control.discovery=\(snapshot.discovery.phase.rawValue)")
    lines.append("tunnel.relay_host=\(snapshot.relayHost ?? "none")")
    lines.append("tunnel.protocol=\(snapshot.relayProtocol ?? "none")")

    if driftPairs.isEmpty {
      lines.append("drift=none")
    } else {
      lines.append("drift=\(driftPairs.joined(separator: ","))")
    }
    return Rendering(text: lines.joined(separator: "\n"), hasDrift: !driftPairs.isEmpty)
  }

  // MARK: - Kernel routes

  // Counts the scoped routes present on the relay tunnel's utun by parsing the
  // routing table: find the interface owning the tunnel's own IPv4 host route,
  // then count the other routes bound to that interface. Returns nil when the
  // table cannot be read or the tunnel interface is not present.
  private static func kernelTunnelRouteCount(
    tunnelIPv4: String, tunnelIPv6: String
  ) -> Int? {
    guard !tunnelIPv4.isEmpty, let table = routingTable() else {
      return nil
    }
    let tunnelV4 = IP.V4(tunnelIPv4)
    let tunnelV6 = IP.V6(tunnelIPv6)
    let rows = table.split(separator: "\n").map { row in
      row.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
    guard let tunnelInterface = tunnelInterfaceName(rows: rows, tunnelIPv4: tunnelIPv4)
    else {
      return nil
    }
    return rows.count { columns in
      guard columns.count >= routeMinimumColumns,
        columns[routeInterfaceColumn] == tunnelInterface,
        let destination = RouteDestination(
          netstatDestination: columns[routeDestinationColumn]
        )
      else {
        return false
      }
      return !destination.isScaffolding(tunnelV4: tunnelV4, tunnelV6: tunnelV6)
    }
  }

  // The utun owning the tunnel's own IPv4 host route, the marker that a row's
  // interface belongs to the relay tunnel rather than another VPN.
  private static func tunnelInterfaceName(
    rows: [[String]], tunnelIPv4: String
  ) -> String? {
    let match = rows.first { columns in
      columns.count >= routeMinimumColumns
        && columns[routeDestinationColumn] == tunnelIPv4
        && columns[routeInterfaceColumn].hasPrefix("utun")
    }
    return match?[routeInterfaceColumn]
  }

  private static func routingTable() -> String? {
    relayStateLogger.notice("relay state reading kernel routing table")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-rn"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      relayStateLogger.error(
        """
        relay state netstat launch failed \
        details=\(error.localizedDescription, privacy: .public) recovery=report-unknown
        """
      )
      return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}

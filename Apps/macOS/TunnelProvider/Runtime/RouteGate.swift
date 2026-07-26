//
//  RouteGate.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Network
import NetworkExtension

// MARK: - RouteGate

/// Owns which routes and DNS the tunnel actually installs, independent of
/// WireGuard. WireGuard's adapter applies its generated network settings through
/// the provider's `setTunnelNetworkSettings`; the provider routes that call
/// through here so the adapter stays a dumb crypto engine. The gate holds a
/// program-owned scoped route set and the config's DNS servers, and installs
/// both only while the iPhone link is up, stripping captured routes to none and
/// withdrawing DNS while it is down, so the Mac tunnel stays connected with no
/// captured traffic and its normal resolver until the relay is reachable. The
/// adapter's own derived routes are discarded, so the breadth of the WireGuard
/// cryptokey allowed IPs never widens the captured route set. DNS withdrawal on
/// link loss matters for an all-traffic config, whose DNS server is reachable
/// only over the tunnel: when the link drops the Mac must fall back to its own
/// resolver rather than a tunnel resolver it can no longer reach.
final class RouteGate: @unchecked Sendable {
  private let lock = NSLock()
  private var settings: NEPacketTunnelNetworkSettings?
  private var programIPv4Routes: [NEIPv4Route] = []
  private var programIPv6Routes: [NEIPv6Route] = []
  private var programDNSServers: [String] = []
  private var programDNSSearchDomains: [String] = []
  private var installed = false

  /// The public resolvers published for an all-traffic config that supplies no
  /// `DNS =` line, so names resolve over the tunnel. Cloudflare's anycast
  /// addresses are reachable from any full-tunnel exit. Each is published only
  /// when the tunnel captures that address family.
  private static let allTrafficFallbackIPv4DNSServer = "1.1.1.1"
  private static let allTrafficFallbackIPv6DNSServer = "2606:4700:4700::1111"

  /// Records the adapter's requested settings, keeping its tunnel addresses and
  /// replacing its captured routes with the program's scoped set gated by the
  /// current link state.
  func record(_ requested: NEPacketTunnelNetworkSettings?) -> NEPacketTunnelNetworkSettings? {
    lock.lock()
    defer { lock.unlock() }
    settings = requested
    return gatedLocked()
  }

  /// Sets the program's scoped captured route set and returns the settings to
  /// re-apply, or nil when the adapter has not supplied settings yet. Setting
  /// the routes before the adapter's first apply ensures the tunnel never
  /// installs a wider route even briefly.
  func setProgramRoutes(
    ipv4: [NEIPv4Route],
    ipv6: [NEIPv6Route]
  ) -> NEPacketTunnelNetworkSettings? {
    lock.lock()
    defer { lock.unlock() }
    programIPv4Routes = ipv4
    programIPv6Routes = ipv6
    guard settings != nil else {
      return nil
    }
    return gatedLocked()
  }

  /// Sets the program's DNS servers and search domains from the config and
  /// returns the settings to re-apply, or nil when the adapter has not supplied
  /// settings yet. Empty servers mean the tunnel publishes no DNS, leaving the
  /// system resolver in place, which is the case for a scoped config with no
  /// `DNS =` line.
  func setProgramDNS(
    servers: [String],
    searchDomains: [String]
  ) -> NEPacketTunnelNetworkSettings? {
    lock.lock()
    defer { lock.unlock() }
    programDNSServers = servers
    programDNSSearchDomains = searchDomains
    guard settings != nil else {
      return nil
    }
    return gatedLocked()
  }

  /// Sets the link state and returns the settings to re-apply, or nil when the
  /// adapter has not supplied settings yet.
  func setInstalled(_ value: Bool) -> NEPacketTunnelNetworkSettings? {
    lock.lock()
    defer { lock.unlock() }
    installed = value
    guard settings != nil else {
      return nil
    }
    return gatedLocked()
  }

  var isInstalled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return installed
  }

  /// The first IPv4 and IPv6 interface addresses from the recorded settings, so
  /// the status snapshot can report the tunnel's assigned addresses. Each is
  /// empty when the adapter has not supplied that family yet.
  func recordedAddresses() -> (ipv4: String, ipv6: String) {
    lock.lock()
    defer { lock.unlock() }
    let ipv4 = settings?.ipv4Settings?.addresses.first ?? ""
    let ipv6 = settings?.ipv6Settings?.addresses.first ?? ""
    return (ipv4, ipv6)
  }

  private func gatedLocked() -> NEPacketTunnelNetworkSettings? {
    guard let settings else {
      return nil
    }
    settings.ipv4Settings?.includedRoutes = installed ? programIPv4Routes : []
    settings.ipv6Settings?.includedRoutes = installed ? programIPv6Routes : []
    settings.dnsSettings = installed ? makeDNSSettingsLocked() : nil
    return settings
  }

  /// The DNS settings to publish while the link is up, or nil when the tunnel
  /// should keep the system resolver. `matchDomains = [""]` makes the tunnel
  /// resolver authoritative for every query, so it overrides any system resolver,
  /// which is what an all-traffic config needs to resolve names over the tunnel.
  private func makeDNSSettingsLocked() -> NEDNSSettings? {
    let servers = resolvedDNSServersLocked()
    guard !servers.isEmpty else {
      return nil
    }
    let dnsSettings = NEDNSSettings(servers: servers)
    dnsSettings.searchDomains = programDNSSearchDomains
    dnsSettings.matchDomains = [""]
    return dnsSettings
  }

  /// The DNS servers to publish. A config `DNS =` line wins. When the config
  /// supplies none, an address family gets a public fallback resolver only when
  /// the tunnel both carries an address in that family and captures all of that
  /// family's traffic. Both conditions matter. Without a tunnel address in the
  /// family the resolver has no source address to be reached from, so its queries
  /// would leave over a physical interface, which is the leak this exists to
  /// prevent. Without full capture the system's own resolver is still reachable
  /// and keeps working, so publishing an override would only override something
  /// that already answers.
  private func resolvedDNSServersLocked() -> [String] {
    if !programDNSServers.isEmpty {
      return programDNSServers
    }
    var servers: [String] = []
    if tunnelCarriesIPv4Locked(), capturesAllIPv4TrafficLocked() {
      servers.append(Self.allTrafficFallbackIPv4DNSServer)
    }
    if tunnelCarriesIPv6Locked(), capturesAllIPv6TrafficLocked() {
      servers.append(Self.allTrafficFallbackIPv6DNSServer)
    }
    return servers
  }

  /// Whether the tunnel holds an IPv4 address, so an IPv4 resolver has a source
  /// address to be reached from. A config whose interface declares only an IPv6
  /// address yields no IPv4 tunnel address here.
  private func tunnelCarriesIPv4Locked() -> Bool {
    settings?.ipv4Settings?.addresses.isEmpty == false
  }

  /// Whether the tunnel holds an IPv6 address, the IPv6 counterpart of
  /// `tunnelCarriesIPv4Locked()`.
  private func tunnelCarriesIPv6Locked() -> Bool {
    settings?.ipv6Settings?.addresses.isEmpty == false
  }

  /// Whether the captured IPv4 routes cover the whole address space, written as
  /// `0.0.0.0/0` or as the equivalent `0.0.0.0/1` and `128.0.0.0/1` pair. The
  /// subnet masks are generated from the prefix length rather than copied from
  /// the config, so comparing them as text is exact.
  private func capturesAllIPv4TrafficLocked() -> Bool {
    let hasDefaultRoute = programIPv4Routes.contains { route in
      route.destinationSubnetMask == "0.0.0.0"
    }
    if hasDefaultRoute {
      return true
    }
    let halfRoutes = programIPv4Routes.filter { $0.destinationSubnetMask == "128.0.0.0" }
    let halfAddresses = halfRoutes.compactMap { IPv4Address($0.destinationAddress) }
    let halfBits = halfAddresses.compactMap { Self.leadingBit(of: $0.rawValue) }
    return halfBits.contains(0) && halfBits.contains(1)
  }

  /// Whether the captured IPv6 routes cover the whole address space, written as
  /// `::/0` or as the equivalent `::/1` and `8000::/1` pair.
  private func capturesAllIPv6TrafficLocked() -> Bool {
    let hasDefaultRoute = programIPv6Routes.contains { route in
      route.destinationNetworkPrefixLength.intValue == 0
    }
    if hasDefaultRoute {
      return true
    }
    let halfRoutes = programIPv6Routes.filter { route in
      route.destinationNetworkPrefixLength.intValue == 1
    }
    let halfAddresses = halfRoutes.compactMap { IPv6Address($0.destinationAddress) }
    let halfBits = halfAddresses.compactMap { Self.leadingBit(of: $0.rawValue) }
    return halfBits.contains(0) && halfBits.contains(1)
  }

  /// Which half of the address space a `/1` route covers, read from the parsed
  /// address rather than its text. A config carries its addresses through
  /// verbatim, so `::`, `0::`, and `0:0:0:0:0:0:0:0` all name the same address
  /// and all have to be recognized.
  private static func leadingBit(of rawValue: Data) -> Int? {
    guard let firstByte = rawValue.first else {
      return nil
    }
    return Int(firstByte >> 7)
  }
}

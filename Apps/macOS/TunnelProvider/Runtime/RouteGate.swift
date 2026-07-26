//
//  RouteGate.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation
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
  /// supplies none, each address family whose traffic the tunnel captures gets a
  /// public fallback resolver, because the system's own resolver for that family
  /// is then reachable only through the tunnel exit, which cannot answer for a
  /// private network. A family the tunnel does not capture keeps its system
  /// resolver, so a single-stack config publishes only the family it captures and
  /// never sends the other family's queries out an uncaptured path.
  private func resolvedDNSServersLocked() -> [String] {
    if !programDNSServers.isEmpty {
      return programDNSServers
    }
    var servers: [String] = []
    if capturesAllIPv4TrafficLocked() {
      servers.append(Self.allTrafficFallbackIPv4DNSServer)
    }
    if capturesAllIPv6TrafficLocked() {
      servers.append(Self.allTrafficFallbackIPv6DNSServer)
    }
    return servers
  }

  /// Whether the captured IPv4 routes cover the whole address space. A config may
  /// write that as `0.0.0.0/0` or as the equivalent `0.0.0.0/1` and `128.0.0.0/1`
  /// pair, so both forms count.
  private func capturesAllIPv4TrafficLocked() -> Bool {
    let hasDefault = programIPv4Routes.contains { $0.destinationSubnetMask == "0.0.0.0" }
    let halfMask = "128.0.0.0"
    let lowerHalf = programIPv4Routes.contains {
      $0.destinationSubnetMask == halfMask && $0.destinationAddress == "0.0.0.0"
    }
    let upperHalf = programIPv4Routes.contains {
      $0.destinationSubnetMask == halfMask && $0.destinationAddress == "128.0.0.0"
    }
    return hasDefault || (lowerHalf && upperHalf)
  }

  /// Whether the captured IPv6 routes cover the whole address space, written as
  /// `::/0` or as the equivalent `::/1` and `8000::/1` pair.
  private func capturesAllIPv6TrafficLocked() -> Bool {
    let hasDefault = programIPv6Routes.contains {
      $0.destinationNetworkPrefixLength.intValue == 0
    }
    let halves = programIPv6Routes.filter {
      $0.destinationNetworkPrefixLength.intValue == 1
    }
    let lowerHalf = halves.contains { $0.destinationAddress == "::" }
    let upperHalf = halves.contains { $0.destinationAddress == "8000::" }
    return hasDefault || (lowerHalf && upperHalf)
  }
}

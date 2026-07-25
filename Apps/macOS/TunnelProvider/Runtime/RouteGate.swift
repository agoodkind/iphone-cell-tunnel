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

  /// The public resolver published for an all-traffic config that supplies no
  /// `DNS =` line, so names resolve over the tunnel. Cloudflare's anycast
  /// addresses are reachable from any full-tunnel exit.
  private static let allTrafficFallbackDNSServers = ["1.1.1.1", "2606:4700:4700::1111"]

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
  /// supplies none but the captured routes include a default route, the config is
  /// all-traffic and the system would otherwise have no resolver reachable over
  /// the tunnel, so a public fallback resolver is published. A scoped config with
  /// no default route keeps the system resolver by publishing none.
  private func resolvedDNSServersLocked() -> [String] {
    if !programDNSServers.isEmpty {
      return programDNSServers
    }
    if programRoutesIncludeDefaultLocked() {
      return Self.allTrafficFallbackDNSServers
    }
    return []
  }

  /// Whether the captured routes include an IPv4 or IPv6 default route, the mark
  /// of an all-traffic config.
  private func programRoutesIncludeDefaultLocked() -> Bool {
    let hasIPv4Default = programIPv4Routes.contains { $0.destinationSubnetMask == "0.0.0.0" }
    let hasIPv6Default = programIPv6Routes.contains {
      $0.destinationNetworkPrefixLength.intValue == 0
    }
    return hasIPv4Default || hasIPv6Default
  }
}

//
//  RouteGate.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
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

  /// The settings to hand to the system: what the tunnel asked for, with the captured
  /// routes and the resolvers this gate owns written over it.
  ///
  /// Each call builds a separate object rather than editing the recorded one again. The
  /// recorded settings stay as the tunnel supplied them, which is what makes them a
  /// reliable record of the tunnel's own addresses, and the system is handed something it
  /// has not already been given.
  private func gatedLocked() -> NEPacketTunnelNetworkSettings? {
    guard let settings else {
      return nil
    }
    let gated = NEPacketTunnelNetworkSettings(
      tunnelRemoteAddress: settings.tunnelRemoteAddress)
    gated.mtu = settings.mtu
    // The adapter sets this when the configuration names no MTU, and it is the
    // allowance for what encapsulation adds to every packet. Dropping it would leave
    // the tunnel sizing packets as though nothing wrapped them.
    gated.tunnelOverheadBytes = settings.tunnelOverheadBytes
    gated.ipv4Settings = rebuiltIPv4(from: settings.ipv4Settings)
    gated.ipv6Settings = rebuiltIPv6(from: settings.ipv6Settings)
    gated.dnsSettings = installed ? makeDNSSettingsLocked() : nil
    return gated
  }

  /// The tunnel's own IPv4 addresses with this gate's captured routes written over them,
  /// or nil when the tunnel carries no IPv4.
  private func rebuiltIPv4(from source: NEIPv4Settings?) -> NEIPv4Settings? {
    guard let source else {
      return nil
    }
    let rebuilt = NEIPv4Settings(
      addresses: source.addresses, subnetMasks: source.subnetMasks)
    rebuilt.includedRoutes = installed ? programIPv4Routes : []
    rebuilt.excludedRoutes = source.excludedRoutes
    return rebuilt
  }

  /// The IPv6 counterpart of `rebuiltIPv4(from:)`.
  private func rebuiltIPv6(from source: NEIPv6Settings?) -> NEIPv6Settings? {
    guard let source else {
      return nil
    }
    let rebuilt = NEIPv6Settings(
      addresses: source.addresses, networkPrefixLengths: source.networkPrefixLengths)
    rebuilt.includedRoutes = installed ? programIPv6Routes : []
    rebuilt.excludedRoutes = source.excludedRoutes
    return rebuilt
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

  /// The resolvers to publish, which are the ones the configuration names and no
  /// others. A named resolver whose family the tunnel does not carry is dropped,
  /// since it would have no source address to be answered from.
  private func resolvedDNSServersLocked() -> [String] {
    publishableResolvers(
      named: programDNSServers,
      tunnelCarriesIPv4: tunnelCarriesIPv4Locked(),
      tunnelCarriesIPv6: tunnelCarriesIPv6Locked()
    )
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
}

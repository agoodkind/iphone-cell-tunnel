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

/// Owns which routes the tunnel actually installs, independent of WireGuard.
/// WireGuard's adapter applies its generated network settings through the
/// provider's `setTunnelNetworkSettings`; the provider routes that call through
/// here so the adapter stays a dumb crypto engine. The gate holds a program-owned
/// scoped route set and installs it only while the iPhone link is up, stripping
/// captured routes to none while it is down, so the Mac tunnel stays connected
/// with no captured traffic until the relay is reachable. The adapter's own
/// derived routes are discarded, so the breadth of the WireGuard cryptokey
/// allowed IPs never widens the captured route set.
final class RouteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: NEPacketTunnelNetworkSettings?
    private var programIPv4Routes: [NEIPv4Route] = []
    private var programIPv6Routes: [NEIPv6Route] = []
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
        return settings
    }
}

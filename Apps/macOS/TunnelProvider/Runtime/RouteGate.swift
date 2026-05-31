//
//  RouteGate.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import Foundation
import NetworkExtension

// MARK: - RouteGate

/// Owns which routes the tunnel actually installs, independent of WireGuard.
/// WireGuard's adapter applies its generated network settings through the
/// provider's `setTunnelNetworkSettings`; the provider routes that call through
/// here so the adapter stays a dumb crypto engine. The gate records the
/// adapter's requested settings, then installs the config's routes only while
/// the iPhone link is up and strips them to none while it is down, so the Mac
/// tunnel stays connected with no captured traffic until the relay is reachable.
final class RouteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: NEPacketTunnelNetworkSettings?
    private var savedIPv4Routes: [NEIPv4Route]?
    private var savedIPv6Routes: [NEIPv6Route]?
    private var installed = false

    /// Records the adapter's requested settings and returns the settings to
    /// apply now, with routes gated by the current link state.
    func record(_ requested: NEPacketTunnelNetworkSettings?) -> NEPacketTunnelNetworkSettings? {
        lock.lock()
        defer { lock.unlock() }
        settings = requested
        savedIPv4Routes = requested?.ipv4Settings?.includedRoutes
        savedIPv6Routes = requested?.ipv6Settings?.includedRoutes
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

    private func gatedLocked() -> NEPacketTunnelNetworkSettings? {
        guard let settings else {
            return nil
        }
        settings.ipv4Settings?.includedRoutes = installed ? (savedIPv4Routes ?? []) : []
        settings.ipv6Settings?.includedRoutes = installed ? (savedIPv6Routes ?? []) : []
        return settings
    }
}

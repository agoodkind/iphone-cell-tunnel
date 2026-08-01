//
//  RouteGateResolverSwapTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import NetworkExtension
import Testing

@testable import CellTunnelTunnelRuntime

// MARK: - Constants

private let swapTunnelRemoteAddress = "10.250.10.1"
private let swapTunnelIPv4Address = "10.250.10.3"
private let swapTunnelIPv4Mask = "255.255.255.255"
private let swapTunnelIPv6Address = "3d06:bad:b01:a::3"
private let swapTunnelIPv6PrefixLength: NSNumber = 128
private let firstResolver = "10.250.10.1"
private let secondResolver = "1.1.1.1"

// MARK: - RouteGateResolverSwapTests

/// Covers what the tunnel is asked to publish when a running tunnel changes configuration.
///
/// Swapping configurations on a running tunnel does not change the resolvers a person
/// actually gets. These tests fix which half of that is at fault: they assert what the
/// gate hands to the system, so a failure here means the gate is wrong and a pass means
/// the gate is right and the system is not adopting what it is given.
@Suite("Route gate resolver swaps")
struct RouteGateResolverSwapTests {
  @Test("naming new resolvers replaces the ones already published")
  func namingNewResolversReplacesThem() {
    let gate = RouteGate()
    _ = gate.record(tunnelSettings())
    _ = gate.setInstalled(true)
    _ = gate.setProgramDNS(servers: [firstResolver], searchDomains: [])

    let settings = gate.setProgramDNS(servers: [secondResolver], searchDomains: [])

    #expect(settings?.dnsSettings?.servers == [secondResolver])
  }

  /// A configuration naming no resolver must withdraw the ones in force, because leaving
  /// them would keep sending queries somewhere the person did not choose.
  @Test("naming no resolver withdraws the ones already published")
  func namingNoResolverWithdrawsThem() {
    let gate = RouteGate()
    _ = gate.record(tunnelSettings())
    _ = gate.setInstalled(true)
    _ = gate.setProgramDNS(servers: [firstResolver, secondResolver], searchDomains: [])

    let settings = gate.setProgramDNS(servers: [], searchDomains: [])

    #expect(settings?.dnsSettings == nil)
  }

  /// The gate reports settings to apply only once the tunnel has supplied its own, so a
  /// swap that arrives first is held rather than applied against nothing.
  @Test("a swap before the tunnel supplies settings reports nothing to apply")
  func swapBeforeSettingsReportsNothing() {
    let gate = RouteGate()

    #expect(gate.setProgramDNS(servers: [firstResolver], searchDomains: []) == nil)
  }

  private func tunnelSettings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(
      tunnelRemoteAddress: swapTunnelRemoteAddress)
    settings.ipv4Settings = NEIPv4Settings(
      addresses: [swapTunnelIPv4Address],
      subnetMasks: [swapTunnelIPv4Mask]
    )
    settings.ipv6Settings = NEIPv6Settings(
      addresses: [swapTunnelIPv6Address],
      networkPrefixLengths: [swapTunnelIPv6PrefixLength]
    )
    return settings
  }
}

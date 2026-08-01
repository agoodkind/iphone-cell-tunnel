//
//  RouteGateAddressTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import NetworkExtension
import Testing

@testable import CellTunnelTunnelRuntime

// MARK: - Constants

private let tunnelRemoteAddress = "10.250.10.1"
private let tunnelIPv4Address = "10.250.10.3"
private let tunnelIPv4Mask = "255.255.255.255"
private let tunnelIPv6Address = "3d06:bad:b01:a::3"
private let tunnelIPv6PrefixLength: NSNumber = 128

// MARK: - RouteGateAddressTests

/// Covers the addresses the tunnel reports as its own.
///
/// A person reads these as the `ipv4` and `ipv6` lines of the status output, and they are
/// how someone confirms the tunnel came up with the addresses their configuration asked
/// for. They are read from whatever settings the tunnel last applied, so a tunnel that has
/// applied none must report nothing rather than a stale or invented address.
@Suite("Route gate reported addresses")
struct RouteGateAddressTests {
  @Test("a tunnel that has applied no settings reports no addresses")
  func noSettingsReportsNoAddresses() {
    let gate = RouteGate()

    let addresses = gate.recordedAddresses()

    #expect(addresses.ipv4.isEmpty)
    #expect(addresses.ipv6.isEmpty)
  }

  @Test("both families are reported once the tunnel applies them")
  func bothFamiliesAreReported() {
    let gate = RouteGate()
    _ = gate.record(settingsCarrying(ipv4: true, ipv6: true))

    let addresses = gate.recordedAddresses()

    #expect(addresses.ipv4 == tunnelIPv4Address)
    #expect(addresses.ipv6 == tunnelIPv6Address)
  }

  /// A configuration naming only one family leaves the other genuinely absent, so the
  /// status output must not imply an address the tunnel does not hold.
  @Test("a family the tunnel does not carry is reported as absent")
  func uncarriedFamilyIsAbsent() {
    let gate = RouteGate()
    _ = gate.record(settingsCarrying(ipv4: true, ipv6: false))

    let addresses = gate.recordedAddresses()

    #expect(addresses.ipv4 == tunnelIPv4Address)
    #expect(addresses.ipv6.isEmpty)
  }

  /// Withdrawing the captured routes leaves the tunnel connected, so it still reports the
  /// addresses it holds.
  @Test("withdrawing routes does not withdraw the reported addresses")
  func withdrawingRoutesKeepsAddresses() {
    let gate = RouteGate()
    _ = gate.record(settingsCarrying(ipv4: true, ipv6: true))

    _ = gate.setInstalled(false)

    let addresses = gate.recordedAddresses()
    #expect(addresses.ipv4 == tunnelIPv4Address)
    #expect(addresses.ipv6 == tunnelIPv6Address)
  }

  private func settingsCarrying(ipv4: Bool, ipv6: Bool) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
    if ipv4 {
      settings.ipv4Settings = NEIPv4Settings(
        addresses: [tunnelIPv4Address],
        subnetMasks: [tunnelIPv4Mask]
      )
    }
    if ipv6 {
      settings.ipv6Settings = NEIPv6Settings(
        addresses: [tunnelIPv6Address],
        networkPrefixLengths: [tunnelIPv6PrefixLength]
      )
    }
    return settings
  }
}

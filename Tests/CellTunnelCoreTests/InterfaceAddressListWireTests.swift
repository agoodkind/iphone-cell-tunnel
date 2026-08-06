//
//  InterfaceAddressListWireTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-05.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - InterfaceAddressListWireTests

/// Covers the egress interface's addresses travelling on the snapshot. The app read
/// them itself, once per poll, from a system call it made on the render path.
struct InterfaceAddressListWireTests {
  @Test func travelsOnTheWire() throws {
    let addresses = InterfaceAddressList(ipv4: ["10.0.0.2"], ipv6: ["fd00::2"])
    let snapshot = TunnelDaemonStatusSnapshot(deviceInterfaceAddresses: addresses)

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: encoded)

    #expect(decoded.deviceInterfaceAddresses == addresses)
  }

  /// A producer that predates the field says nothing rather than an empty list, which a
  /// reader tells apart from an interface that genuinely holds no address.
  @Test func absentFromAnOlderProducer() {
    #expect(TunnelDaemonStatusSnapshot().deviceInterfaceAddresses == nil)
  }
}

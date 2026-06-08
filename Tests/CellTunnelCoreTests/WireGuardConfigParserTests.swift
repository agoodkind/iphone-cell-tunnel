//
//  WireGuardConfigParserTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

private let fixturePrivateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
private let fixturePublicKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
private let peerEndpointPort: UInt16 = 51_820

// MARK: - WireGuardConfigParserTests

struct WireGuardConfigParserTests {
  @Test func validConfigParsesInterfaceAddressAndPeerEndpoint() throws {
    let config = """
      [Interface]
      PrivateKey = \(fixturePrivateKey)
      Address = 10.0.0.2/32, fd00::2/128

      [Peer]
      PublicKey = \(fixturePublicKey)
      Endpoint = relay.example.com:51820
      AllowedIPs = 203.0.113.7/32, 2001:db8::7/128
      PersistentKeepalive = 25
      """

    let parsedConfig = try WireGuardConfigParser.parse(config)
    let expectedEndpoint = WireGuardEndpoint(host: "relay.example.com", port: peerEndpointPort)

    #expect(
      parsedConfig.interface.addresses == [
        AddressPrefix(family: .ipv4, address: "10.0.0.2", prefixLength: 32),
        AddressPrefix(family: .ipv6, address: "fd00::2", prefixLength: 128),
      ]
    )
    #expect(parsedConfig.peer.endpoint == expectedEndpoint)
  }

  @Test func missingPeerSectionThrowsMissingPeer() {
    let config = """
      [Interface]
      PrivateKey = \(fixturePrivateKey)
      Address = 10.0.0.2/32
      """

    let thrownError = captureError {
      _ = try WireGuardConfigParser.parse(config)
    }

    guard let configError = thrownError as? WireGuardConfigError else {
      Issue.record("expected missingPeer error, got \(String(describing: thrownError))")
      return
    }
    switch configError {
    case .missingPeer:
      break
    default:
      Issue.record("expected missingPeer error, got \(String(describing: configError))")
    }
  }
}

private func captureError(during operation: () throws -> Void) -> Error? {
  do {
    try operation()
    return nil
  } catch {
    return error
  }
}

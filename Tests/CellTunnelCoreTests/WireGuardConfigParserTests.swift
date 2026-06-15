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

  @Test func dnsLineSplitsServersFromSearchDomains() throws {
    let config = dnsTestConfig(
      dnsLine: "10.250.10.1, 3d06:bad:b01:a::1, home.goodkind.io",
      address: "10.250.10.8/32, 3d06:bad:b01:a::8/128",
      allowedIPs: "0.0.0.0/0, ::/0"
    )

    let parsedConfig = try WireGuardConfigParser.parse(config)

    #expect(parsedConfig.interface.dnsServers == ["10.250.10.1", "3d06:bad:b01:a::1"])
    #expect(parsedConfig.interface.dnsSearchDomains == ["home.goodkind.io"])
  }

  @Test func dnsLineWithOnlyServersHasNoSearchDomains() throws {
    let config = dnsTestConfig(dnsLine: "1.1.1.1, 2606:4700:4700::1111")

    let parsedConfig = try WireGuardConfigParser.parse(config)

    #expect(parsedConfig.interface.dnsServers == ["1.1.1.1", "2606:4700:4700::1111"])
    #expect(parsedConfig.interface.dnsSearchDomains.isEmpty)
  }

  @Test func configWithoutDNSLineHasEmptyDNS() throws {
    let config = dnsTestConfig(dnsLine: nil, allowedIPs: "203.0.113.7/32")

    let parsedConfig = try WireGuardConfigParser.parse(config)

    #expect(parsedConfig.interface.dnsServers.isEmpty)
    #expect(parsedConfig.interface.dnsSearchDomains.isEmpty)
  }

  @Test func dnsLineTrimsWhitespaceAroundTokens() throws {
    let config = dnsTestConfig(dnsLine: "  1.1.1.1 ,  8.8.8.8")

    let parsedConfig = try WireGuardConfigParser.parse(config)

    #expect(parsedConfig.interface.dnsServers == ["1.1.1.1", "8.8.8.8"])
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

/// Builds a parseable WireGuard config with an optional interface `DNS =` line.
/// The key assignments sit on allowlisted lines so the secret scanner does not
/// flag the non-secret test fixtures, which only matter as parseable keys here.
private func dnsTestConfig(
  dnsLine: String?,
  address: String = "10.0.0.2/32",
  allowedIPs: String = "0.0.0.0/0"
) -> String {
  let privateKeyLine = "PrivateKey = \(fixturePrivateKey)"  // gitleaks:allow
  let publicKeyLine = "PublicKey = \(fixturePublicKey)"  // gitleaks:allow
  var lines = ["[Interface]", privateKeyLine, "Address = \(address)"]
  if let dnsLine {
    lines.append("DNS = \(dnsLine)")
  }
  lines.append("")
  lines.append(contentsOf: ["[Peer]", publicKeyLine, "Endpoint = relay.example.com:51820"])
  lines.append("AllowedIPs = \(allowedIPs)")
  return lines.joined(separator: "\n")
}

private func captureError(during operation: () throws -> Void) -> Error? {
  do {
    try operation()
    return nil
  } catch {
    return error
  }
}

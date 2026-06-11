//
//  RouteDestination.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import IP

// MARK: - Constants

/// The dotted-quad octet count a BSD-shortened IPv4 destination pads up to, and
/// the full prefix lengths a bare destination implies.
private let ipv4OctetCount = 4
private let ipv4FullPrefixBits: UInt8 = 32
private let ipv6FullPrefixBits: UInt8 = 128

/// The scaffolding networks by their RFC definitions, parsed through swift-ip so
/// the membership checks are real CIDR containment rather than string matching:
/// IPv4 multicast (RFC 5771), IPv4 link-local (RFC 3927), the limited broadcast
/// (RFC 919), IPv6 multicast (RFC 4291 section 2.7), and IPv6 link-local
/// (RFC 4291 section 2.5.6).
private let scaffoldingV4Blocks: [IP.Block<IP.V4>] = [
  "224.0.0.0/4", "169.254.0.0/16", "255.255.255.255/32",
].compactMap(IP.Block<IP.V4>.init)
private let scaffoldingV6Blocks: [IP.Block<IP.V6>] = [
  "ff00::/8", "fe80::/10",
].compactMap(IP.Block<IP.V6>.init)

// MARK: - RouteDestination

/// One parsed routing-table destination as a CIDR block, built on swift-ip's
/// `IP.Block` so address parsing and containment follow the RFC forms rather
/// than string comparison. The only local normalization is for the BSD table's
/// own spellings, which are not CIDR: a `%zone` is stripped, a shortened IPv4
/// destination like `10.250/16` pads to a full dotted quad, a bare address
/// gains its full prefix length, and `default` reads as the zero-length block.
enum RouteDestination {
  case v4(IP.Block<IP.V4>)
  case v6(IP.Block<IP.V6>)

  // MARK: - Parsing

  init?(netstatDestination: String) {
    guard let normalized = Self.normalize(netstatDestination) else {
      return nil
    }
    if let block = IP.Block<IP.V6>.init(normalized) {
      self = .v6(block)
      return
    }
    if let block = IP.Block<IP.V4>.init(normalized) {
      self = .v4(block)
      return
    }
    return nil
  }

  // Rewrites a BSD routing-table destination into strict CIDR notation, or nil
  // for a row that is not a network destination (a section header, a link row).
  private static func normalize(_ destination: String) -> String? {
    if destination == "default" {
      return "0.0.0.0/0"
    }
    let withoutZone =
      destination.split(separator: "%").first.map(String.init) ?? destination
    let pieces = withoutZone.split(separator: "/", omittingEmptySubsequences: false)
    let addressPart = pieces.first.map(String.init) ?? withoutZone
    let prefixPart = pieces.count > 1 ? String(pieces[1]) : nil

    if addressPart.contains(":") {
      let bits = prefixPart ?? "\(ipv6FullPrefixBits)"
      return "\(addressPart)/\(bits)"
    }
    guard let padded = paddedIPv4(addressPart) else {
      return nil
    }
    let bits = prefixPart ?? "\(ipv4FullPrefixBits)"
    return "\(padded)/\(bits)"
  }

  // Pads a BSD-shortened dotted quad like `10.250` to `10.250.0.0`. A
  // destination with anything other than one to four numeric components is not
  // an IPv4 address.
  private static func paddedIPv4(_ value: String) -> String? {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...ipv4OctetCount).contains(components.count),
      components.allSatisfy({ component in UInt8(component) != nil })
    else {
      return nil
    }
    let padded =
      components.map(String.init)
      + Array(repeating: "0", count: ipv4OctetCount - components.count)
    return padded.joined(separator: ".")
  }

  // MARK: - Classification

  /// Whether this destination is interface scaffolding rather than a program
  /// route: a member of the RFC multicast, link-local, or broadcast blocks, or
  /// a network containing one of the tunnel's own addresses, which covers the
  /// tunnel's host route, its connected subnet, and a default.
  func isScaffolding(tunnelV4: IP.V4?, tunnelV6: IP.V6?) -> Bool {
    switch self {
    case .v4(let block):
      if scaffoldingV4Blocks.contains(where: { scaffold in
        scaffold.contains(block.base)
      }) {
        return true
      }
      guard let tunnelV4 else {
        return false
      }
      return block.contains(tunnelV4)
    case .v6(let block):
      if scaffoldingV6Blocks.contains(where: { scaffold in
        scaffold.contains(block.base)
      }) {
        return true
      }
      guard let tunnelV6 else {
        return false
      }
      return block.contains(tunnelV6)
    }
  }
}

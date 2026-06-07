//
//  InterfaceAddressLookup.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - InterfaceAddressLookup

/// Reads the IPv4 and IPv6 address bound to a named interface from the BSD
/// interface list. The egress interface and the carrying link interface both read
/// their addresses through this one lookup.
public enum InterfaceAddressLookup {
  /// The first IPv4 and IPv6 address on the named interface. Global addresses
  /// describe the egress interface, so it skips link-local by default; the
  /// carrying link asks to keep link-local, since the address a USB bridge assigns
  /// is link-local and is exactly what the link rows report.
  public static func addresses(
    forInterface name: String, includeLinkLocal: Bool = false
  ) -> AddressPair {
    guard !name.isEmpty else {
      return .empty
    }
    var listPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&listPointer) == 0 else {
      return .empty
    }
    defer { freeifaddrs(listPointer) }
    var ipv4: String?
    var ipv6: String?
    var cursor = listPointer
    while let entry = cursor {
      cursor = entry.pointee.ifa_next
      guard String(cString: entry.pointee.ifa_name) == name else {
        continue
      }
      guard let address = entry.pointee.ifa_addr else {
        continue
      }
      let family = address.pointee.sa_family
      if family == UInt8(AF_INET), ipv4 == nil {
        ipv4 = host(from: address, family: family, includeLinkLocal: includeLinkLocal)
      } else if family == UInt8(AF_INET6), ipv6 == nil {
        ipv6 = host(from: address, family: family, includeLinkLocal: includeLinkLocal)
      }
    }
    return AddressPair(ipv4: ipv4, ipv6: ipv6)
  }

  /// Formats a socket address as a numeric host string. It strips the IPv6 scope
  /// suffix, and drops a link-local address unless the caller keeps it.
  private static func host(
    from address: UnsafeMutablePointer<sockaddr>, family: UInt8, includeLinkLocal: Bool
  ) -> String? {
    let length =
      family == UInt8(AF_INET)
      ? socklen_t(MemoryLayout<sockaddr_in>.size)
      : socklen_t(MemoryLayout<sockaddr_in6>.size)
    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let result = getnameinfo(
      address, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
    guard result == 0 else {
      return nil
    }
    var resolvedHost = String(cString: hostBuffer)
    if let scopeSeparator = resolvedHost.firstIndex(of: "%") {
      resolvedHost = String(resolvedHost[..<scopeSeparator])
    }
    let isLinkLocal =
      resolvedHost.hasPrefix("fe80:") || resolvedHost.hasPrefix("169.254.")
    if !includeLinkLocal, isLinkLocal {
      return nil
    }
    return resolvedHost
  }
}

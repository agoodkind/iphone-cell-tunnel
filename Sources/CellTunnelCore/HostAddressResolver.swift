//
//  HostAddressResolver.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - HostAddressResolver

/// Resolves a host to its numeric IPv4 and IPv6 addresses through the system
/// resolver. A WireGuard endpoint is configured by hostname, so the relay section
/// resolves that hostname to the server's A and AAAA records rather than showing
/// the hostname in an address row. An IP literal resolves to itself. The call is
/// synchronous, so a caller resolves once when the endpoint is known and caches
/// the result rather than resolving on the status path.
public enum HostAddressResolver {
    /// The resolved address pair for a host. A family with no record is `nil`.
    public struct Resolved: Sendable, Equatable {
        public var ipv4: String?
        public var ipv6: String?

        public init(ipv4: String? = nil, ipv6: String? = nil) {
            self.ipv4 = ipv4
            self.ipv6 = ipv6
        }
    }

    /// Resolves `host` to its first IPv4 and first IPv6 numeric address. Returns an
    /// empty pair when the host is empty or the lookup fails.
    public static func resolve(host: String) -> Resolved {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Resolved()
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var entries: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(trimmed, nil, &hints, &entries) == 0 else {
            return Resolved()
        }
        defer { freeaddrinfo(entries) }
        var ipv4: String?
        var ipv6: String?
        var cursor = entries
        while let entry = cursor {
            cursor = entry.pointee.ai_next
            guard let address = entry.pointee.ai_addr else {
                continue
            }
            let family = entry.pointee.ai_family
            if family == AF_INET, ipv4 == nil {
                ipv4 = numericHost(address, length: entry.pointee.ai_addrlen)
            } else if family == AF_INET6, ipv6 == nil {
                ipv6 = numericHost(address, length: entry.pointee.ai_addrlen)
            }
        }
        return Resolved(ipv4: ipv4, ipv6: ipv6)
    }

    /// Formats a socket address as a numeric host string, stripping any IPv6 scope
    /// suffix so the value reads as a plain address.
    private static func numericHost(
        _ address: UnsafeMutablePointer<sockaddr>, length: socklen_t
    ) -> String? {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            address, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
        guard status == 0 else {
            return nil
        }
        var host = String(cString: hostBuffer)
        if let scopeSeparator = host.firstIndex(of: "%") {
            host = String(host[..<scopeSeparator])
        }
        return host.isEmpty ? nil : host
    }
}

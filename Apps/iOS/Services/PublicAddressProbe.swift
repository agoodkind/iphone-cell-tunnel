//
//  PublicAddressProbe.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - PublicAddressSource

/// The address-reflection endpoints the probe reads, one per family. Swapping the
/// source is a one-line change here, so a different reflector or a DNS-based method
/// can replace it without touching the probe or the controller. A runtime setting
/// to choose the source is tracked separately and is not wired yet.
struct PublicAddressSource: Sendable {
    let ipv4URLString: String
    let ipv6URLString: String

    /// ident.me over HTTPS. `4.ident.me` resolves only an A record and `6.ident.me`
    /// only AAAA, so each request is forced onto its own family and the body is the
    /// reflected address.
    static let identMe = PublicAddressSource(
        ipv4URLString: "https://4.ident.me",
        ipv6URLString: "https://6.ident.me"
    )
}

// MARK: - PublicAddressProbe

/// Reads this device's public IPv4 and IPv6 addresses with one request per family
/// against a configurable source. It returns what the internet sees over the
/// device's current default path, which on the iPhone serving as the uplink is the
/// cellular public address. A family with no answer returns nil.
struct PublicAddressProbe {
    var source: PublicAddressSource = .identMe

    /// Probes both families concurrently and returns the pair.
    func probe() async -> (ipv4: String?, ipv6: String?) {
        async let ipv4 = fetch(urlString: source.ipv4URLString)
        async let ipv6 = fetch(urlString: source.ipv6URLString)
        return (await ipv4, await ipv6)
    }

    private func fetch(urlString: String) async -> String? {
        guard let url = URL(string: urlString) else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(bytes: data, encoding: .utf8) else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logger.notice(
                """
                public address probe failed url=\(urlString, privacy: .public) \
                error=\(String(describing: error), privacy: .public) recovery=report-no-address
                """
            )
            return nil
        }
    }
}

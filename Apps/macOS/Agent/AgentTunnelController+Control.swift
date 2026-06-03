//
//  AgentTunnelController+Control.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Control link hosting

extension AgentTunnelController {
    /// The agent hosts the control link because a listener only receives inbound
    /// from the iPhone in a normal process, not inside a NetworkExtension. It
    /// parses the WireGuard server endpoint from the config and hands it to the
    /// listener, which sends it to the iPhone when the iPhone dials in.
    func startControlListener(wireGuardConfig: String) async throws {
        guard let endpoint = Self.serverEndpoint(fromConfig: wireGuardConfig) else {
            logger.error(
                """
                agent control listener start failed \
                reason=no-parseable-endpoint recovery=throw-missing-server-endpoint
                """
            )
            throw AgentTunnelControllerError.missingServerEndpoint
        }
        await controlListener?.stop()
        let listener = AgentControlListener(serverEndpoint: endpoint)
        await listener.setRoutingHandler { [weak self] enabled in
            Task { await self?.setRoutingEnabled(enabled) }
        }
        controlListener = listener
        try await listener.start()
        relayBridge.onPhoneConnected = { [weak self] in
            Task { await self?.handlePhoneLink(up: true) }
        }
        relayBridge.onPhoneDisconnected = { [weak self] in
            Task { await self?.handlePhoneLink(up: false) }
        }
        relayBridge.start(serviceName: ProcessInfo.processInfo.hostName)
        onRelayActiveChange?(true)
        logger.notice(
            """
            agent control listener started host=\(endpoint.host, privacy: .public) \
            port=\(endpoint.port, privacy: .public)
            """
        )
    }

    func stopControlListener() async {
        await controlListener?.stop()
        controlListener = nil
        relayBridge.stop()
        onRelayActiveChange?(false)
        logger.notice("agent control link cleared on tunnel stop")
    }

    // MARK: - Routing control

    /// Records the user's routing choice and reconciles routes against the live
    /// link. Routing on with a link up installs the program routes; routing off
    /// withdraws them. The default is passthrough, so a link comes up carrying
    /// nothing until the user turns routing on.
    func setRoutingEnabled(_ enabled: Bool) async {
        routingEnabled = enabled
        logger.notice(
            "agent routing set enabled=\(enabled, privacy: .public) phoneLinkUp=\(self.phoneLinkUp, privacy: .public)"
        )
        if enabled, phoneLinkUp {
            await signalRouteState(true)
        } else if !enabled {
            await signalRouteState(false)
        }
    }

    /// Tracks the live phone link and reconciles routes. A link coming up installs
    /// routes only when routing is on; a link going down always withdraws them, so
    /// routing resumes by itself when the link returns while routing stays on.
    func handlePhoneLink(up: Bool) async {
        phoneLinkUp = up
        if up {
            if routingEnabled {
                await signalRouteState(true)
            }
        } else {
            await signalRouteState(false)
        }
    }

    // MARK: - Endpoint parsing

    /// Extracts the peer endpoint from the config using WireGuardKit's own
    /// endpoint parser on the `Endpoint =` line, so the agent reuses the library
    /// rather than reimplementing host and port parsing.
    static func serverEndpoint(fromConfig text: String) -> RelayEndpoint? {
        let lines = text.split(omittingEmptySubsequences: false) { character in
            character == "\n" || character == "\r"
        }
        for rawLine in lines {
            guard let value = endpointValue(inLine: String(rawLine)) else {
                continue
            }
            guard let parsed = Endpoint(from: value) else {
                return nil
            }
            return relayEndpoint(from: parsed)
        }
        return nil
    }

    private static func endpointValue(inLine rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if let hashIndex = line.firstIndex(of: "#") {
            line = String(line[..<hashIndex]).trimmingCharacters(in: .whitespaces)
        }
        guard let separator = line.firstIndex(of: "=") else {
            return nil
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        guard key.caseInsensitiveCompare("Endpoint") == .orderedSame else {
            return nil
        }
        return line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
    }

    private static func relayEndpoint(from endpoint: Endpoint) -> RelayEndpoint {
        let port = endpoint.port.rawValue
        switch endpoint.host {
        case .ipv6(let address):
            return RelayEndpoint(addressFamily: .ipv6, host: "\(address)", port: port)
        case .ipv4(let address):
            return RelayEndpoint(addressFamily: .ipv4, host: "\(address)", port: port)
        case .name(let hostname, _):
            return RelayEndpoint(addressFamily: .ipv4, host: hostname, port: port)
        @unknown default:
            return RelayEndpoint(addressFamily: .ipv4, host: "\(endpoint.host)", port: port)
        }
    }
}

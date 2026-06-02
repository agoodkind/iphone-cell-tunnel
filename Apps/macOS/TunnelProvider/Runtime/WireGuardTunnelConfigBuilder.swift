//
//  WireGuardTunnelConfigBuilder.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Network
import WireGuardKit

// The Mac's WireGuard backend never dials the server directly: the relay bind
// redirects every outbound datagram to the iPhone, which resolves the real
// server name (forwarded over the control channel) and reaches it over
// cellular. The peer endpoint here is therefore vestigial, so it carries an IP
// literal rather than the configured hostname, which makes WireGuardKit skip a
// pointless server-name DNS lookup at tunnel start.
private let relayPlaceholderPeerHost = "::1"

// WireGuard cryptokey routing must accept every captured packet for the single
// relay peer, so the peer's allowed IPs span all addresses. The route gate
// decides the operating-system routes the tunnel captures separately from these
// values, so this breadth never widens the captured route set.
private let cryptoAllowedIPRepresentations = ["0.0.0.0/0", "::/0"]

enum WireGuardTunnelConfigBuildError: LocalizedError {
    case invalidEndpointPort(String)
    case invalidInterfaceAddress(String)
    case invalidPeerAllowedIP(String)
    case invalidPeerPublicKey
    case invalidPresharedKey
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .invalidEndpointPort(let value):
            return "wireguard tunnel config invalid endpoint port=\(value)"
        case .invalidInterfaceAddress(let value):
            return "wireguard tunnel config invalid interface address=\(value)"
        case .invalidPeerAllowedIP(let value):
            return "wireguard tunnel config invalid peer allowed ip=\(value)"
        case .invalidPeerPublicKey:
            return "wireguard tunnel config peer public key invalid"
        case .invalidPresharedKey:
            return "wireguard tunnel config peer preshared key invalid"
        case .invalidPrivateKey:
            return "wireguard tunnel config interface private key invalid"
        }
    }
}

// MARK: - WireGuardTunnelConfigBuilder

enum WireGuardTunnelConfigBuilder {
    static func build(
        from parsed: WireGuardClientConfig,
        name: String? = nil
    ) throws -> TunnelConfiguration {
        let interfaceConfig = try makeInterface(parsed.interface)
        let peerConfig = try makePeer(parsed.peer)
        return TunnelConfiguration(name: name, interface: interfaceConfig, peers: [peerConfig])
    }

    private static func makeInterface(
        _ section: WireGuardInterfaceSection
    ) throws -> InterfaceConfiguration {
        guard
            let privateKeyHex = section.privateKey?.hexValue,
            let privateKey = PrivateKey(hexKey: privateKeyHex)
        else {
            throw WireGuardTunnelConfigBuildError.invalidPrivateKey
        }
        var interfaceConfig = InterfaceConfiguration(privateKey: privateKey)
        interfaceConfig.addresses = try section.addresses.map { prefix in
            try interfaceAddressRange(from: prefix)
        }
        interfaceConfig.listenPort = section.listenPort
        if let mtu = section.mtu {
            interfaceConfig.mtu = UInt16(clamping: mtu)
        }
        return interfaceConfig
    }

    private static func makePeer(_ section: WireGuardPeerSection) throws -> PeerConfiguration {
        guard
            let publicKeyHex = section.publicKey?.hexValue,
            let publicKey = PublicKey(hexKey: publicKeyHex)
        else {
            throw WireGuardTunnelConfigBuildError.invalidPeerPublicKey
        }
        var peerConfig = PeerConfiguration(publicKey: publicKey)
        if let presharedKeyHex = section.presharedKey?.hexValue {
            guard let presharedKey = PreSharedKey(hexKey: presharedKeyHex) else {
                throw WireGuardTunnelConfigBuildError.invalidPresharedKey
            }
            peerConfig.preSharedKey = presharedKey
        }
        peerConfig.allowedIPs = try cryptoAllowedIPRepresentations.map { representation in
            guard let range = IPAddressRange(from: representation) else {
                throw WireGuardTunnelConfigBuildError.invalidPeerAllowedIP(representation)
            }
            return range
        }
        if let parsedEndpoint = section.endpoint {
            peerConfig.endpoint = try endpoint(from: parsedEndpoint)
        }
        peerConfig.persistentKeepAlive = section.persistentKeepaliveSeconds
        return peerConfig
    }

    private static func interfaceAddressRange(
        from prefix: AddressPrefix
    ) throws -> IPAddressRange {
        let representation = "\(prefix.address)/\(prefix.prefixLength)"
        guard let range = IPAddressRange(from: representation) else {
            throw WireGuardTunnelConfigBuildError.invalidInterfaceAddress(representation)
        }
        return range
    }

    private static func endpoint(from parsed: WireGuardEndpoint) throws -> Endpoint {
        guard let port = NWEndpoint.Port(rawValue: parsed.port) else {
            throw WireGuardTunnelConfigBuildError.invalidEndpointPort(String(parsed.port))
        }
        let host = NWEndpoint.Host(relayPlaceholderPeerHost)
        return Endpoint(host: host, port: port)
    }
}

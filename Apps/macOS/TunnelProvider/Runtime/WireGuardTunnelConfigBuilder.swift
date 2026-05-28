import Foundation
import Network
import WireGuardKit

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
        interfaceConfig.addresses = try section.addresses.map { try ipAddressRange(from: $0) }
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
        peerConfig.allowedIPs = try section.allowedIPs.map { prefix in
            try ipAddressRange(from: prefix, asPeerAllowedIP: true)
        }
        if let parsedEndpoint = section.endpoint {
            peerConfig.endpoint = try endpoint(from: parsedEndpoint)
        }
        peerConfig.persistentKeepAlive = section.persistentKeepaliveSeconds
        return peerConfig
    }

    private static func ipAddressRange(
        from prefix: AddressPrefix,
        asPeerAllowedIP: Bool = false
    ) throws -> IPAddressRange {
        let representation = "\(prefix.address)/\(prefix.prefixLength)"
        guard let range = IPAddressRange(from: representation) else {
            if asPeerAllowedIP {
                throw WireGuardTunnelConfigBuildError.invalidPeerAllowedIP(representation)
            }
            throw WireGuardTunnelConfigBuildError.invalidInterfaceAddress(representation)
        }
        return range
    }

    private static func endpoint(from parsed: WireGuardEndpoint) throws -> Endpoint {
        guard let port = NWEndpoint.Port(rawValue: parsed.port) else {
            throw WireGuardTunnelConfigBuildError.invalidEndpointPort(String(parsed.port))
        }
        let host = NWEndpoint.Host(parsed.host)
        return Endpoint(host: host, port: port)
    }
}

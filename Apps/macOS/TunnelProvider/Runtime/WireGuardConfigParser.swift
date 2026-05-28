import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

// X25519 public/private key length in bytes per RFC 7748.
private let wireGuardKeyLengthBytes = 32

// Maximum prefix length for IPv4 and IPv6 address families.
private let ipv4PrefixLengthMax = 32
private let ipv6PrefixLengthMax = 128

// A CIDR-style prefix line "address/length" splits into exactly 2 parts.
private let addressPrefixSplitParts = 2

enum WireGuardConfigError: LocalizedError {
    case fileReadFailed(String)
    case invalidEndpoint(String)
    case invalidKeepalive(String)
    case invalidKey(String)
    case invalidLine(String)
    case invalidMTU(String)
    case invalidPort(String)
    case invalidPrefix(String)
    case invalidSection(String)
    case missingEndpoint
    case missingInterface
    case missingPeer
    case missingPrivateKey
    case missingPublicKey

    var errorDescription: String? {
        switch self {
        case .fileReadFailed(let path):
            return "wireguard config read failed path=\(path)"
        case .invalidEndpoint(let value):
            return "wireguard config invalid endpoint: \(value)"
        case .invalidKeepalive(let value):
            return "wireguard config invalid persistent keepalive: \(value)"
        case .invalidKey(let value):
            return "wireguard config invalid key: \(value)"
        case .invalidLine(let line):
            return "wireguard config invalid line: \(line)"
        case .invalidMTU(let value):
            return "wireguard config invalid mtu: \(value)"
        case .invalidPort(let value):
            return "wireguard config invalid port: \(value)"
        case .invalidPrefix(let value):
            return "wireguard config invalid prefix: \(value)"
        case .invalidSection(let name):
            return "wireguard config invalid section: \(name)"
        case .missingEndpoint:
            return "wireguard config peer missing Endpoint"
        case .missingInterface:
            return "wireguard config missing [Interface] section"
        case .missingPeer:
            return "wireguard config missing [Peer] section"
        case .missingPrivateKey:
            return "wireguard config interface missing PrivateKey"
        case .missingPublicKey:
            return "wireguard config peer missing PublicKey"
        }
    }
}

struct WireGuardKey: Equatable, Sendable {
    let hexValue: String
}

struct WireGuardEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16
    let isIPv6Literal: Bool

    var hostPort: String {
        if isIPv6Literal {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }
}

struct WireGuardInterfaceSection: Equatable, Sendable {
    var privateKey: WireGuardKey?
    var addresses: [AddressPrefix] = []
    var listenPort: UInt16?
    var mtu: Int?
}

struct WireGuardPeerSection: Equatable, Sendable {
    var publicKey: WireGuardKey?
    var presharedKey: WireGuardKey?
    var endpoint: WireGuardEndpoint?
    var allowedIPs: [AddressPrefix] = []
    var persistentKeepaliveSeconds: UInt16?
}

struct WireGuardClientConfig: Equatable, Sendable {
    var interface: WireGuardInterfaceSection
    var peer: WireGuardPeerSection
}

enum WireGuardConfigParser {
    static func load(from url: URL) throws -> WireGuardClientConfig {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error(
                """
                wg tunnel config read failed path=\(url.path, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
            throw WireGuardConfigError.fileReadFailed(url.path)
        }
        return try parse(raw)
    }

    static func parse(_ text: String) throws -> WireGuardClientConfig {
        var interfaceSection = WireGuardInterfaceSection()
        var peerSection = WireGuardPeerSection()
        var section: String?
        var sawInterface = false
        var sawPeer = false

        let lines = text.split(omittingEmptySubsequences: false) { character in
            character == "\n" || character == "\r"
        }
        for rawLine in lines {
            let stripped = stripComment(String(rawLine))
            if stripped.isEmpty {
                continue
            }
            if stripped.hasPrefix("["), stripped.hasSuffix("]") {
                let name = String(stripped.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                switch name {
                case "Interface":
                    section = "Interface"
                    sawInterface = true
                case "Peer":
                    section = "Peer"
                    sawPeer = true
                default:
                    throw WireGuardConfigError.invalidSection(name)
                }
                continue
            }

            guard let separator = stripped.firstIndex(of: "=") else {
                throw WireGuardConfigError.invalidLine(stripped)
            }
            let key = stripped[..<separator].trimmingCharacters(in: .whitespaces)
            let value = stripped[stripped.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)

            switch section {
            case "Interface":
                try applyInterfaceField(key: key, value: value, into: &interfaceSection)
            case "Peer":
                try applyPeerField(key: key, value: value, into: &peerSection)
            default:
                throw WireGuardConfigError.invalidLine(stripped)
            }
        }

        guard sawInterface else {
            throw WireGuardConfigError.missingInterface
        }
        guard sawPeer else {
            throw WireGuardConfigError.missingPeer
        }
        guard interfaceSection.privateKey != nil else {
            throw WireGuardConfigError.missingPrivateKey
        }
        guard peerSection.publicKey != nil else {
            throw WireGuardConfigError.missingPublicKey
        }
        guard peerSection.endpoint != nil else {
            throw WireGuardConfigError.missingEndpoint
        }
        return WireGuardClientConfig(interface: interfaceSection, peer: peerSection)
    }

    private static func stripComment(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let hashIndex = trimmed.firstIndex(of: "#") {
            return trimmed[..<hashIndex].trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func applyInterfaceField(
        key: String,
        value: String,
        into section: inout WireGuardInterfaceSection
    ) throws {
        switch key {
        case "PrivateKey":
            section.privateKey = try decodeKey(value)
        case "Address":
            section.addresses.append(contentsOf: try parsePrefixList(value))
        case "ListenPort":
            section.listenPort = try parsePort(value)
        case "MTU":
            guard let parsed = Int(value), parsed > 0 else {
                throw WireGuardConfigError.invalidMTU(value)
            }
            section.mtu = parsed
        case "DNS", "Table", "PreUp", "PostUp", "PreDown", "PostDown", "SaveConfig", "FwMark":
            break
        default:
            break
        }
    }

    private static func applyPeerField(
        key: String,
        value: String,
        into section: inout WireGuardPeerSection
    ) throws {
        switch key {
        case "PublicKey":
            section.publicKey = try decodeKey(value)
        case "PresharedKey":
            section.presharedKey = try decodeKey(value)
        case "Endpoint":
            section.endpoint = try parseEndpoint(value)
        case "AllowedIPs":
            section.allowedIPs.append(contentsOf: try parsePrefixList(value))
        case "PersistentKeepalive":
            guard let parsed = UInt16(value) else {
                throw WireGuardConfigError.invalidKeepalive(value)
            }
            section.persistentKeepaliveSeconds = parsed
        default:
            break
        }
    }

    private static func decodeKey(_ value: String) throws -> WireGuardKey {
        guard let data = Data(base64Encoded: value) else {
            throw WireGuardConfigError.invalidKey(value)
        }
        guard data.count == wireGuardKeyLengthBytes else {
            throw WireGuardConfigError.invalidKey(value)
        }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return WireGuardKey(hexValue: hex)
    }

    private static func parsePort(_ value: String) throws -> UInt16 {
        guard let parsed = UInt16(value), parsed > 0 else {
            throw WireGuardConfigError.invalidPort(value)
        }
        return parsed
    }

    private static func parsePrefixList(_ value: String) throws -> [AddressPrefix] {
        var prefixes: [AddressPrefix] = []
        for raw in value.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.isEmpty {
                continue
            }
            prefixes.append(try parsePrefix(token))
        }
        return prefixes
    }

    private static func parsePrefix(_ value: String) throws -> AddressPrefix {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let address: String
        let lengthString: String?
        if parts.count == addressPrefixSplitParts {
            address = String(parts[0])
            lengthString = String(parts[1])
        } else {
            address = value
            lengthString = nil
        }
        let family: AddressFamily = address.contains(":") ? .ipv6 : .ipv4
        let defaultLength = family == .ipv4 ? ipv4PrefixLengthMax : ipv6PrefixLengthMax
        let prefixLength: Int
        if let lengthString {
            guard let parsed = Int(lengthString) else {
                throw WireGuardConfigError.invalidPrefix(value)
            }
            prefixLength = parsed
        } else {
            prefixLength = defaultLength
        }
        let bounds = family == .ipv4 ? 0...ipv4PrefixLengthMax : 0...ipv6PrefixLengthMax
        guard bounds.contains(prefixLength) else {
            throw WireGuardConfigError.invalidPrefix(value)
        }
        return AddressPrefix(family: family, address: address, prefixLength: prefixLength)
    }

    private static func parseEndpoint(_ value: String) throws -> WireGuardEndpoint {
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else {
                throw WireGuardConfigError.invalidEndpoint(value)
            }
            let host = String(value[value.index(after: value.startIndex)..<closing])
            let afterClosing = value.index(after: closing)
            guard afterClosing < value.endIndex, value[afterClosing] == ":" else {
                throw WireGuardConfigError.invalidEndpoint(value)
            }
            let portString = String(value[value.index(after: afterClosing)...])
            let port = try parsePort(portString)
            return WireGuardEndpoint(host: host, port: port, isIPv6Literal: true)
        }
        guard let lastColon = value.lastIndex(of: ":") else {
            throw WireGuardConfigError.invalidEndpoint(value)
        }
        let host = String(value[..<lastColon])
        let portString = String(value[value.index(after: lastColon)...])
        let port = try parsePort(portString)
        let isIPv6 = host.contains(":")
        return WireGuardEndpoint(host: host, port: port, isIPv6Literal: isIPv6)
    }
}

extension WireGuardClientConfig {
    func uapiConfig(endpointOverride: WireGuardEndpoint? = nil) -> String {
        var lines: [String] = []
        if let privateKey = interface.privateKey {
            lines.append("private_key=\(privateKey.hexValue)")
        }
        if let listenPort = interface.listenPort {
            lines.append("listen_port=\(listenPort)")
        }
        lines.append("replace_peers=true")
        if let publicKey = peer.publicKey {
            lines.append("public_key=\(publicKey.hexValue)")
        }
        if let presharedKey = peer.presharedKey {
            lines.append("preshared_key=\(presharedKey.hexValue)")
        }
        let endpoint = endpointOverride ?? peer.endpoint
        if let endpoint {
            lines.append("endpoint=\(endpoint.hostPort)")
        }
        lines.append("replace_allowed_ips=true")
        for prefix in peer.allowedIPs {
            lines.append("allowed_ip=\(prefix.address)/\(prefix.prefixLength)")
        }
        if let keepalive = peer.persistentKeepaliveSeconds {
            lines.append("persistent_keepalive_interval=\(keepalive)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

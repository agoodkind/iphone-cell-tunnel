import CellTunnelLog
import Darwin
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)
private let routeMessageBufferSize = 4_096

enum AddressFamily: String, Sendable {
    case ipv4
    case ipv6
}

struct AddressPrefix: Sendable, Equatable {
    let family: AddressFamily
    let address: String
    let prefixLength: Int
}

enum RouteManagerError: LocalizedError {
    case invalidAddress(String)
    case invalidPrefixLength(Int)
    case interfaceNotFound(String)
    case socketFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let value):
            return "route manager invalid address=\(value)"
        case .invalidPrefixLength(let value):
            return "route manager invalid prefix length=\(value)"
        case .interfaceNotFound(let name):
            return "route manager interface not found name=\(name)"
        case .socketFailed(let code):
            return "route manager PF_ROUTE socket() failed errno=\(code)"
        case .writeFailed(let code):
            return "route manager route write failed errno=\(code)"
        case .readFailed(let code):
            return "route manager route read failed errno=\(code)"
        }
    }
}

final class RouteManager {
    private var installedRoutes: [(prefix: AddressPrefix, interface: String)] = []
    private var sequenceCounter: Int32 = 0

    func install(prefixes: [AddressPrefix], onInterface interfaceName: String) throws {
        guard !prefixes.isEmpty else {
            return
        }
        guard let interfaceIndex = interfaceIndex(forName: interfaceName) else {
            throw RouteManagerError.interfaceNotFound(interfaceName)
        }
        for prefix in prefixes {
            try writeRoute(
                type: Int32(RTM_ADD),
                prefix: prefix,
                interfaceName: interfaceName,
                interfaceIndex: interfaceIndex
            )
            installedRoutes.append((prefix: prefix, interface: interfaceName))
            logger.notice(
                """
                route installed family=\(prefix.family.rawValue, privacy: .public) \
                address=\(prefix.address, privacy: .public) \
                prefixLength=\(prefix.prefixLength, privacy: .public) \
                interface=\(interfaceName, privacy: .public)
                """
            )
        }
    }

    func removeAll() throws {
        var firstError: Error?
        let snapshot = installedRoutes
        installedRoutes.removeAll(keepingCapacity: false)
        for entry in snapshot.reversed() {
            do {
                let index = interfaceIndex(forName: entry.interface)
                try writeRoute(
                    type: Int32(RTM_DELETE),
                    prefix: entry.prefix,
                    interfaceName: entry.interface,
                    interfaceIndex: index ?? 0
                )
                logger.notice(
                    """
                    route removed family=\(entry.prefix.family.rawValue, privacy: .public) \
                    address=\(entry.prefix.address, privacy: .public) \
                    prefixLength=\(entry.prefix.prefixLength, privacy: .public) \
                    interface=\(entry.interface, privacy: .public)
                    """
                )
            } catch {
                if firstError == nil {
                    firstError = error
                }
                logger.error(
                    """
                    route remove failed family=\(entry.prefix.family.rawValue, privacy: .public) \
                    address=\(entry.prefix.address, privacy: .public) \
                    prefixLength=\(entry.prefix.prefixLength, privacy: .public) \
                    interface=\(entry.interface, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """
                )
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func writeRoute(
        type messageType: Int32,
        prefix: AddressPrefix,
        interfaceName: String,
        interfaceIndex: UInt32
    ) throws {
        var sockets: [Data] = []
        switch prefix.family {
        case .ipv4:
            let destination = try ipv4SockaddrData(address: prefix.address)
            let mask = try ipv4MaskSockaddrData(prefixLength: prefix.prefixLength)
            sockets.append(destination)
            sockets.append(linkSockaddrData(interfaceIndex: interfaceIndex, name: interfaceName))
            sockets.append(mask)
        case .ipv6:
            let destination = try ipv6SockaddrData(address: prefix.address)
            let mask = try ipv6MaskSockaddrData(prefixLength: prefix.prefixLength)
            sockets.append(destination)
            sockets.append(linkSockaddrData(interfaceIndex: interfaceIndex, name: interfaceName))
            sockets.append(mask)
        }

        let flags: Int32 = Int32(RTF_UP) | Int32(RTF_STATIC) | Int32(RTF_HOST)
        let addressMask: Int32 = Int32(RTA_DST) | Int32(RTA_GATEWAY) | Int32(RTA_NETMASK)

        sequenceCounter &+= 1
        let sequence = sequenceCounter

        var header = rt_msghdr()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + sockets.reduce(0) { $0 + $1.count })
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(messageType)
        header.rtm_index = UInt16(interfaceIndex)
        header.rtm_flags = flags
        header.rtm_addrs = addressMask
        header.rtm_seq = sequence
        header.rtm_pid = getpid()

        var packet = Data()
        withUnsafeBytes(of: &header) { headerBytes in
            packet.append(contentsOf: headerBytes)
        }
        for socket in sockets {
            packet.append(socket)
        }

        let socketDescriptor = socket(PF_ROUTE, SOCK_RAW, 0)
        guard socketDescriptor >= 0 else {
            throw RouteManagerError.socketFailed(errno: errno)
        }
        defer { Darwin.close(socketDescriptor) }

        let writeStatus = packet.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else {
                return -1
            }
            return Darwin.write(socketDescriptor, base, packet.count)
        }
        if writeStatus < 0 {
            throw RouteManagerError.writeFailed(errno: errno)
        }
    }

    private func interfaceIndex(forName name: String) -> UInt32? {
        let index = name.withCString { if_nametoindex($0) }
        return index == 0 ? nil : index
    }

    private func ipv4SockaddrData(address: String) throws -> Data {
        var storage = sockaddr_in()
        storage.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        storage.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &storage.sin_addr) == 1 else {
            throw RouteManagerError.invalidAddress(address)
        }
        return withUnsafeBytes(of: &storage) { Data($0) }
    }

    private func ipv4MaskSockaddrData(prefixLength: Int) throws -> Data {
        guard (0...32).contains(prefixLength) else {
            throw RouteManagerError.invalidPrefixLength(prefixLength)
        }
        var storage = sockaddr_in()
        storage.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        storage.sin_family = sa_family_t(AF_INET)
        let maskValue: UInt32 = prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
        storage.sin_addr.s_addr = maskValue.bigEndian
        return withUnsafeBytes(of: &storage) { Data($0) }
    }

    private func ipv6SockaddrData(address: String) throws -> Data {
        var storage = sockaddr_in6()
        storage.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        storage.sin6_family = sa_family_t(AF_INET6)
        guard inet_pton(AF_INET6, address, &storage.sin6_addr) == 1 else {
            throw RouteManagerError.invalidAddress(address)
        }
        return withUnsafeBytes(of: &storage) { Data($0) }
    }

    private func ipv6MaskSockaddrData(prefixLength: Int) throws -> Data {
        guard (0...128).contains(prefixLength) else {
            throw RouteManagerError.invalidPrefixLength(prefixLength)
        }
        var storage = sockaddr_in6()
        storage.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        storage.sin6_family = sa_family_t(AF_INET6)
        var maskBytes = [UInt8](repeating: 0, count: 16)
        var remaining = prefixLength
        var byteIndex = 0
        while remaining >= 8, byteIndex < 16 {
            maskBytes[byteIndex] = 0xFF
            byteIndex += 1
            remaining -= 8
        }
        if remaining > 0, byteIndex < 16 {
            maskBytes[byteIndex] = UInt8(0xFF << (8 - remaining)) & 0xFF
        }
        withUnsafeMutableBytes(of: &storage.sin6_addr) { destination in
            for offset in 0..<16 {
                destination[offset] = maskBytes[offset]
            }
        }
        return withUnsafeBytes(of: &storage) { Data($0) }
    }

    private func linkSockaddrData(interfaceIndex: UInt32, name: String) -> Data {
        var storage = sockaddr_dl()
        storage.sdl_len = UInt8(MemoryLayout<sockaddr_dl>.size)
        storage.sdl_family = sa_family_t(AF_LINK)
        storage.sdl_index = UInt16(interfaceIndex)
        let nameBytes = Array(name.utf8)
        let copyCount = min(nameBytes.count, 12)
        storage.sdl_nlen = UInt8(copyCount)
        storage.sdl_alen = 0
        storage.sdl_slen = 0
        withUnsafeMutableBytes(of: &storage.sdl_data) { destination in
            for offset in 0..<copyCount {
                destination[offset] = nameBytes[offset]
            }
        }
        return withUnsafeBytes(of: &storage) { Data($0) }
    }
}

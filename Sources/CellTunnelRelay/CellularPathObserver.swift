//
//  CellularPathObserver.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

private let logger = CellTunnelLog.logger(category: .relay)

/// Runs the cellular `NWPathMonitor` on its own serial queue and holds the latest
/// `CellularPathSnapshot` behind a `Mutex` so the packet-tunnel provider can read
/// it for status reporting without hopping to the MainActor. The provider owns one
/// instance, starts it in `startTunnel`, and cancels it in `stopTunnel`.
final class CellularPathObserver: @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "CellTunnelPhone.CellularMonitor")
    private let monitor: NWPathMonitor
    private let requiredInterfaceType: NWInterface.InterfaceType?
    private let latestSnapshot = Mutex(CellularPathSnapshot())

    /// Watches a specific interface type, or the general path when
    /// `requiredInterfaceType` is nil. The device pins the cellular radio; the
    /// in-process simulator host, which has no cellular radio, watches the general
    /// path so a satisfied host network drives the connected status the same way a
    /// live cellular path does on device.
    init(requiredInterfaceType: NWInterface.InterfaceType?) {
        self.requiredInterfaceType = requiredInterfaceType
        if let requiredInterfaceType {
            monitor = NWPathMonitor(requiredInterfaceType: requiredInterfaceType)
        } else {
            monitor = NWPathMonitor()
        }
    }

    var snapshot: CellularPathSnapshot {
        latestSnapshot.withLock { $0 }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            let egress = egressInterface(in: path)
            let addresses: (ipv4: String?, ipv6: String?)
            if let egress {
                addresses = Self.interfaceAddresses(named: egress.name)
            } else {
                addresses = (ipv4: nil, ipv6: nil)
            }
            let newSnapshot = CellularPathSnapshot(
                isSatisfied: path.status == .satisfied,
                supportsIPv4: path.supportsIPv4,
                supportsIPv6: path.supportsIPv6,
                interfaceName: egress?.name,
                interfaceIndex: egress?.index,
                ipv4Address: addresses.ipv4,
                ipv6Address: addresses.ipv6,
                transportDisplayName: egress.map(Self.transportDisplayName(for:))
            )
            latestSnapshot.withLock { $0 = newSnapshot }
            logger.info(
                """
                egress path updated satisfied=\(path.status == .satisfied, privacy: .public) \
                ipv4=\(path.supportsIPv4, privacy: .public) \
                ipv6=\(path.supportsIPv6, privacy: .public) \
                interface=\(egressInterface?.name ?? "none", privacy: .public)
                """
            )
        }
        monitor.start(queue: monitorQueue)
        logger.info("egress monitor started")
    }

    // The egress interface for this path: the required type when one is set, such
    // as the cellular radio on device, otherwise the path's primary non-loopback
    // interface, such as Wi-Fi in the simulator.
    private func egressInterface(in path: NWPath) -> NWInterface? {
        let interfaces = path.availableInterfaces
        if let requiredInterfaceType {
            let match = interfaces.first { interface in
                interface.type == requiredInterfaceType
            }
            if let match {
                return match
            }
        }
        return interfaces.first { interface in
            interface.type != .loopback
        }
    }

    // The egress transport by defined name, derived from the interface type.
    private static func transportDisplayName(for interface: NWInterface) -> String {
        switch interface.type {
        case .cellular:
            return "Cellular"
        case .wifi:
            return "Wi-Fi"
        case .wiredEthernet:
            return "Ethernet"
        case .loopback:
            return "Loopback"
        case .other:
            return "Other"
        @unknown default:
            return "Other"
        }
    }

    func stop() {
        monitor.cancel()
        latestSnapshot.withLock { $0 = CellularPathSnapshot() }
        logger.info("cellular monitor stopped")
    }

    // MARK: - Interface addresses

    /// Reads the first global IPv4 and IPv6 address bound to the named interface
    /// from the BSD interface list, so the screen shows the device's own cellular
    /// addresses. Link-local addresses are skipped because they are not the
    /// device-facing identity the screen reports.
    private static func interfaceAddresses(named name: String) -> (ipv4: String?, ipv6: String?) {
        var listPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&listPointer) == 0 else {
            return (nil, nil)
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
                ipv4 = globalAddress(from: address, family: family)
            } else if family == UInt8(AF_INET6), ipv6 == nil {
                ipv6 = globalAddress(from: address, family: family)
            }
        }
        return (ipv4, ipv6)
    }

    /// Formats a socket address as a numeric host string, returning nil for a
    /// link-local address so only the routable address reaches the screen.
    private static func globalAddress(
        from address: UnsafeMutablePointer<sockaddr>, family: UInt8
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
        var host = String(cString: hostBuffer)
        if let scopeSeparator = host.firstIndex(of: "%") {
            host = String(host[..<scopeSeparator])
        }
        if host.hasPrefix("fe80:") || host.hasPrefix("169.254.") {
            return nil
        }
        return host
    }
}

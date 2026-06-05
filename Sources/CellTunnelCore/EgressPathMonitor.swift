//
//  EgressPathMonitor.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - EgressPath

/// One reading of a host's egress path: whether it is satisfied, the families it
/// supports, the egress interface identity, that interface's own addresses, and the
/// transport by defined name. Both the iPhone cellular status and the public-address
/// re-probe read this one shape.
public struct EgressPath: Sendable, Equatable {
    public var isSatisfied: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    public var interfaceName: String?
    public var interfaceIndex: Int?
    public var addresses: AddressPair
    public var transportDisplayName: String?

    public init(
        isSatisfied: Bool = false,
        supportsIPv4: Bool = false,
        supportsIPv6: Bool = false,
        interfaceName: String? = nil,
        interfaceIndex: Int? = nil,
        addresses: AddressPair = .empty,
        transportDisplayName: String? = nil
    ) {
        self.isSatisfied = isSatisfied
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
        self.addresses = addresses
        self.transportDisplayName = transportDisplayName
    }
}

// MARK: - EgressPathMonitor

/// Watches a host's egress path with `NWPathMonitor` and reports each reading. It
/// is the one place an egress change is detected: the iPhone cellular status reads
/// it for the device interface rows, and both hosts re-probe their public address
/// when it changes. It holds the latest reading behind a `Mutex` so a reader on any
/// thread can take it without hopping, and fires `onChange` on every update.
///
/// `@unchecked Sendable`: the latest reading is behind a `Mutex`, `onChange` is set
/// once before `start()`, and the handler runs on the monitor's own serial queue.
public final class EgressPathMonitor: @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "io.goodkind.celltunnel.egressMonitor")
    private let monitor: NWPathMonitor
    private let requiredInterfaceType: NWInterface.InterfaceType?

    /// Fired with each new reading on the monitor queue. Set before `start()`.
    public var onChange: (@Sendable (EgressPath) -> Void)?

    /// Watches a specific interface type, such as the cellular radio on device, or
    /// the general default path when `requiredInterfaceType` is nil, such as the
    /// Mac's own egress or the in-process simulator host network.
    public init(requiredInterfaceType: NWInterface.InterfaceType?) {
        self.requiredInterfaceType = requiredInterfaceType
        if let requiredInterfaceType {
            monitor = NWPathMonitor(requiredInterfaceType: requiredInterfaceType)
        } else {
            monitor = NWPathMonitor()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            let reading = Self.reading(from: path, requiredInterfaceType: requiredInterfaceType)
            logger.info(
                """
                egress path updated satisfied=\(reading.isSatisfied, privacy: .public) \
                ipv4=\(reading.supportsIPv4, privacy: .public) \
                ipv6=\(reading.supportsIPv6, privacy: .public) \
                interface=\(reading.interfaceName ?? "none", privacy: .public)
                """
            )
            onChange?(reading)
        }
        monitor.start(queue: monitorQueue)
        logger.info("egress monitor started")
    }

    public func stop() {
        monitor.cancel()
        logger.info("egress monitor stopped")
    }

    // MARK: - Reading

    private static func reading(
        from path: NWPath,
        requiredInterfaceType: NWInterface.InterfaceType?
    ) -> EgressPath {
        let egress = egressInterface(in: path, requiredInterfaceType: requiredInterfaceType)
        let addresses =
            egress.map { InterfaceAddressLookup.addresses(forInterface: $0.name) } ?? .empty
        return EgressPath(
            isSatisfied: path.status == .satisfied,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            interfaceName: egress?.name,
            interfaceIndex: egress?.index,
            addresses: addresses,
            transportDisplayName: egress.map(transportDisplayName(for:))
        )
    }

    // The egress interface for this path: the required type when one is set, such as
    // the cellular radio on device, otherwise the path's primary non-loopback
    // interface, such as Wi-Fi or the Mac's wired link.
    private static func egressInterface(
        in path: NWPath,
        requiredInterfaceType: NWInterface.InterfaceType?
    ) -> NWInterface? {
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
}

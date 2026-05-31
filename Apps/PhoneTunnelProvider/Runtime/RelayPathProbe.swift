//
//  RelayPathProbe.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let relayServiceType = "_cellrelay._udp"

// MARK: - RelayMacInterface

/// One interface the agent's relay service is reachable on right now, with the
/// scored class and the handle needed to dial it. The forwarder dials one link
/// per interface, pinning the connection to `interface`, so the wired USB link,
/// Wi-Fi LAN, and AWDL each become their own warm link.
struct RelayMacInterface: Sendable, Equatable {
    let interfaceName: String
    let linkClass: RelayLinkClass
    let endpoint: NWEndpoint
    let interface: NWInterface
}

// MARK: - RelayPathProbe

/// Discovers every interface the Mac agent is reachable on and reports the set
/// whenever it changes. It is the sensing half of multi-link selection: it only
/// browses and reports, never dials the data plane, so it cannot stop traffic.
///
/// Inside a packet-tunnel extension `NWPathMonitor` only sees the extension's own
/// scoped paths, the cellular egress and the tunnel, never the local links to the
/// Mac. A Bonjour browse is the one mechanism that surfaces them from here. The
/// browse runs with peer-to-peer on, so a single browse surfaces the agent over
/// the wired USB link, Wi-Fi LAN, and AWDL at once; each result carries the
/// interfaces it was seen on. The forwarder keeps one warm link per interface.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`, and the browser starts with `.start(queue: queue)`.
final class RelayPathProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CellTunnelPhone.RelayPathProbe")
    private var browser: NWBrowser?
    private var lastInterfaceNames: Set<String> = []

    /// Called with the current set of reachable Mac interfaces whenever it
    /// changes. Set before `start()`. Fires on the probe queue; the forwarder
    /// hops onto its own queue as needed.
    var onDiscover: (@Sendable ([RelayMacInterface]) -> Void)?

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.startBrowseOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
            self?.lastInterfaceNames = []
            logger.notice("relay path probe stopped")
        }
    }

    // MARK: - Discovery browse

    private func startBrowseOnQueue() {
        let parameters = NWParameters()
        // Peer-to-peer on so one browse surfaces the agent over the wired USB
        // link, Wi-Fi LAN, and AWDL; each result lists the interfaces it reached.
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: relayServiceType, domain: nil)
        let nwBrowser = NWBrowser(for: descriptor, using: parameters)
        nwBrowser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state)
        }
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        nwBrowser.start(queue: queue)
        browser = nwBrowser
        logger.notice(
            "relay path probe browsing service=\(relayServiceType, privacy: .public)"
        )
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            logger.notice("relay path probe browser ready")
        case .failed(let error):
            logger.error(
                "relay path probe browser failed error=\(error.localizedDescription, privacy: .public)"
            )
            emitIfChanged([])
        default:
            break
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var byInterface: [String: RelayMacInterface] = [:]
        for result in results {
            guard case .service = result.endpoint else {
                continue
            }
            for interface in result.interfaces where interface.type != .loopback {
                let candidate = RelayMacInterface(
                    interfaceName: interface.name,
                    linkClass: Self.linkClass(for: interface),
                    endpoint: result.endpoint,
                    interface: interface
                )
                byInterface[interface.name] = candidate
            }
        }
        emitIfChanged(Array(byInterface.values))
    }

    /// Emits only when the interface set changes, so steady-state browse refreshes
    /// do not churn the forwarder. The forwarder reaps a dead link on its own.
    private func emitIfChanged(_ interfaces: [RelayMacInterface]) {
        let names = Set(interfaces.map(\.interfaceName))
        guard names != lastInterfaceNames else {
            return
        }
        lastInterfaceNames = names
        logger.notice(
            "relay path probe interfaces changed names=\(names.sorted().joined(separator: ","), privacy: .public)"
        )
        onDiscover?(interfaces)
    }

    private static func linkClass(for interface: NWInterface) -> RelayLinkClass {
        switch interface.type {
        case .wiredEthernet:
            return .wired
        case .wifi:
            return .wifiLan
        case .cellular:
            return .cellular
        case .loopback:
            return .loopback
        case .other:
            // USB CDC-NCM Ethernet surfaces as `.other`; only AWDL is the slow
            // peer-to-peer path, so a non-AWDL other interface is a fast link.
            return interface.name.hasPrefix("awdl") ? .peerToPeer : .wired
        @unknown default:
            return .other
        }
    }
}

//
//  RelayDeviceBrowser.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-28.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

private let logger = CellTunnelLog.logger(category: .daemon)

private let relayDeviceBonjourServiceType = "_cellrelay._udp"
private let relayDeviceBrowserQueueLabel = "io.goodkind.celltunnel.agent.relayBrowser"

/// A single discovered Bonjour relay device, in a small copyable Sendable form
/// the agent can hand back over the control channel without exposing Network
/// framework types. `identifier` matches the extension's discovery format so a
/// service id selected against the agent's browser stays comparable end to end.
struct DiscoveredRelayDevice: Equatable, Hashable, Sendable {
    let identifier: String
    let serviceName: String
    let serviceType: String
    let domain: String
    let interfaceIndex: Int
}

// MARK: - RelayDeviceBrowser

/// Runs a continuous `NWBrowser` for the iPhone relay Bonjour type on one serial
/// queue, independent of the VPN tunnel, so the agent can list nearby relays and
/// resolve a selection without the extension being up. Every Network object and
/// every mutation of `devices` happens on `queue`; reads from other threads hop
/// onto `queue` synchronously. The `@unchecked Sendable` contract holds because
/// no stored property is touched off `queue`.
final class RelayDeviceBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: relayDeviceBrowserQueueLabel)
    private var browser: NWBrowser?
    private var devices: [DiscoveredRelayDevice] = []
    private let didLogStateUpdate = Atomic<Bool>(false)

    func start() {
        queue.async { [weak self] in
            self?.beginBrowsing()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.endBrowsing()
        }
    }

    func snapshot() -> [DiscoveredRelayDevice] {
        queue.sync {
            devices
        }
    }

    private func beginBrowsing() {
        guard browser == nil else {
            return
        }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: relayDeviceBonjourServiceType,
            domain: nil
        )
        let nwBrowser = NWBrowser(for: descriptor, using: parameters)
        nwBrowser.stateUpdateHandler = { [weak self] state in
            self?.handleStateUpdate(state)
        }
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.applyResults(results)
        }
        nwBrowser.start(queue: queue)
        browser = nwBrowser
        logger.notice(
            "relay device browser started type=\(relayDeviceBonjourServiceType, privacy: .public)"
        )
    }

    private func endBrowsing() {
        guard let nwBrowser = browser else {
            devices.removeAll()
            return
        }
        browser = nil
        nwBrowser.cancel()
        devices.removeAll()
        logger.notice("relay device browser stopped")
    }

    private func handleStateUpdate(_ state: NWBrowser.State) {
        if didLogStateUpdate.compareExchange(
            expected: false,
            desired: true,
            ordering: .relaxed
        ).exchanged {
            logger.notice(
                "relay device browser state=\(String(describing: state), privacy: .public)"
            )
        }
        guard case .failed = state else {
            return
        }
        restartAfterFailure()
    }

    private func restartAfterFailure() {
        browser?.cancel()
        browser = nil
        logger.notice("relay device browser failed recovery=restart")
        beginBrowsing()
    }

    private func applyResults(_ results: Set<NWBrowser.Result>) {
        var next: [DiscoveredRelayDevice] = []
        for result in results {
            guard let device = device(from: result) else {
                continue
            }
            next.append(device)
        }
        devices = next
    }

    private func device(from result: NWBrowser.Result) -> DiscoveredRelayDevice? {
        guard case let .service(name, type, domain, interface) = result.endpoint else {
            return nil
        }
        let interfaceIndex = interface.map { Int($0.index) } ?? 0
        let identifier = "\(name).\(type).\(domain)#\(interfaceIndex)"
        return DiscoveredRelayDevice(
            identifier: identifier,
            serviceName: name,
            serviceType: type,
            domain: domain,
            interfaceIndex: interfaceIndex
        )
    }
}

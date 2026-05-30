//
//  RelayBrowse.swift
//  CellTunnelDev
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let relayBrowseLogger = CellTunnelLog.logger(category: .daemon)
private let relayBrowseServiceType = "_cellrelay._udp"
private let relayBrowseQueueLabel = "io.goodkind.celltunnel.dev.relayBrowse"
private let relayBrowseDefaultSeconds = 8

// MARK: - Namespace

enum RelayBrowse {}

// MARK: - Browse command

/// Browses `_cellrelay._udp` in the foreground for the requested duration,
/// printing browser state transitions and each discovered service with its
/// interface index, then cancels and returns. Running the same NWBrowser the
/// agent's RelayDeviceBrowser uses, but outside the launchd-launched agent,
/// isolates the Network-framework browse from the agent's XPC and process
/// context: a service surfaced here that the agent does not list points at the
/// agent's runtime context rather than the browse parameters.
func runRelayBrowse(_ arguments: [String]) throws {
    let durationSeconds = try parseRelayBrowseDuration(arguments)
    printToolOutput(
        "relay-browse: browsing \(relayBrowseServiceType) for \(durationSeconds)s")
    relayBrowseLogger.notice(
        "relay-browse starting durationSeconds=\(durationSeconds, privacy: .public)")

    let queue = DispatchQueue(label: relayBrowseQueueLabel)
    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    let descriptor = NWBrowser.Descriptor.bonjour(
        type: relayBrowseServiceType, domain: nil)
    let browser = NWBrowser(for: descriptor, using: parameters)

    browser.stateUpdateHandler = { state in
        printToolOutput("relay-browse: state=\(String(describing: state))")
    }
    browser.browseResultsChangedHandler = { results, _ in
        printRelayBrowseResults(results)
    }

    let done = DispatchSemaphore(value: 0)
    browser.start(queue: queue)
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(durationSeconds)) {
        done.signal()
    }
    done.wait()
    browser.cancel()
    relayBrowseLogger.notice("relay-browse finished")
    printToolOutput("relay-browse: done")
}

// MARK: - Result rendering

/// Prints the current browse result set, one line per discovered Bonjour service
/// with its resolved interface index.
private func printRelayBrowseResults(_ results: Set<NWBrowser.Result>) {
    printToolOutput("relay-browse: \(results.count) result(s)")
    for result in results {
        guard
            case .service(let name, let type, let domain, let interface) =
                result.endpoint
        else {
            continue
        }
        let interfaceIndex = interface.map { Int($0.index) } ?? 0
        printToolOutput(
            """
              service name=\(name) type=\(type) domain=\(domain) \
            ifIndex=\(interfaceIndex) iface=\(String(describing: interface))
            """
        )
    }
}

// MARK: - Argument parsing

/// Parses the optional positional duration in seconds, defaulting when absent.
private func parseRelayBrowseDuration(_ arguments: [String]) throws -> Int {
    guard let first = arguments.first else {
        return relayBrowseDefaultSeconds
    }
    guard let value = Int(first), value >= 1 else {
        throw ToolError.usage(
            "relay-browse [seconds]; seconds must be a positive integer")
    }
    return value
}

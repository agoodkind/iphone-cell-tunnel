//
//  RelayControl.swift
//  CellTunnelDev
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation

// MARK: - Constants

private let relayControlLogger = CellTunnelLog.logger(category: .daemon)
private let relayDiscoverTimeoutSeconds: Double = 15
// Slightly above the provider's 90s WireGuard handshake-retry window so relay-up
// waits for the real connect outcome instead of giving up while WireGuard is still
// retrying the handshake over the cellular relay.
private let relayConnectTimeoutSeconds: Double = 95
private let relayPollIntervalSeconds: Double = 1
private let relayConfigOptionName = "--config"
private let relayNameOptionName = "--relay"
private let relayDiscoverTimeoutOptionName = "--discover-timeout"
private let relayConnectTimeoutOptionName = "--connect-timeout"
private let relayOptionStride = 2

// MARK: - Namespace

enum RelayControl {}

// MARK: - relay-discover

/// Starts agent relay discovery and polls until at least one relay device appears
/// or the timeout elapses, then prints the discovery snapshot. This is the
/// deterministic replacement for calling `devices` directly, which reads the
/// browser snapshot without ever starting the browser and so returns empty.
func runRelayDiscover(_ arguments: [String]) throws {
    let timeoutSeconds = try parseRelayTimeout(
        arguments,
        optionName: relayDiscoverTimeoutOptionName,
        fallback: relayDiscoverTimeoutSeconds)
    relayControlLogger.notice(
        "relay-discover starting timeoutSeconds=\(Int(timeoutSeconds), privacy: .public)")
    printToolOutput("relay-discover: discovering, waiting up to \(Int(timeoutSeconds))s")
    try runRelayCommand { client in
        _ = try await client.startRelayDiscovery()
        let snapshot = try await waitForRelayServices(
            client: client, timeoutSeconds: timeoutSeconds, preferredName: nil)
        printToolOutput(snapshot.renderedOutput)
        if snapshot.services.isEmpty {
            printToolOutput("relay-discover: no relay devices found within timeout")
        }
    }
}

// MARK: - relay-up

/// Brings the relay tunnel up end to end in one agent session: starts discovery,
/// waits for the relay device, selects it, starts the tunnel with the given
/// WireGuard config, then polls status until the tunnel reports running or the
/// connect timeout elapses. Replaces manually chaining start-discovery, select,
/// and start across separate invocations, which races the agent idle timeout and
/// the lazily started browser.
func runRelayUp(_ arguments: [String]) throws {
    let options = try parseRelayUpOptions(arguments)
    relayControlLogger.notice("relay-up starting")
    printToolOutput("relay-up: config=\(options.configPath)")
    try runRelayCommand { client in
        _ = try await client.startRelayDiscovery()
        let discovered = try await waitForRelayServices(
            client: client,
            timeoutSeconds: options.discoverTimeoutSeconds,
            preferredName: options.relayName)
        guard
            let device = selectRelayDevice(
                from: discovered, preferredName: options.relayName)
        else {
            throw ToolError.failure(
                "relay-up: no relay device discovered within \(Int(options.discoverTimeoutSeconds))s"
            )
        }
        printToolOutput("relay-up: selecting \(device.serviceName) (\(device.id))")
        _ = try await client.selectRelayService(serviceID: device.id)
        printToolOutput("relay-up: starting tunnel")
        let settings = TunnelStartSettings(wireGuardConfigPath: options.configPath)
        _ = try await client.startTunnel(settings: settings)
        let status = try await waitForTunnelRunning(
            client: client, timeoutSeconds: options.connectTimeoutSeconds)
        printToolOutput(status.renderedOutput)
        printToolOutput(
            status.running
                ? "relay-up: connected" : "relay-up: NOT connected within timeout")
    }
}

// MARK: - relay-status / relay-down

/// Prints the current tunnel daemon status snapshot from the agent.
func runRelayStatus(_ arguments: [String]) throws {
    _ = arguments
    relayControlLogger.notice("relay-status requested")
    try runRelayCommand { client in
        let status = try await client.status()
        printToolOutput(status.renderedOutput)
    }
}

/// Stops the tunnel through the agent and prints the resulting status snapshot.
func runRelayDown(_ arguments: [String]) throws {
    _ = arguments
    relayControlLogger.notice("relay-down requested")
    try runRelayCommand { client in
        let status = try await client.stopTunnel()
        printToolOutput(status.renderedOutput)
        printToolOutput("relay-down: stopped")
    }
}

// MARK: - reset-mac

/// Removes the saved Mac VPN configuration through the agent and prints the
/// resulting status snapshot, so a clean test starts with no leftover state.
func runResetMac(_ arguments: [String]) throws {
    _ = arguments
    relayControlLogger.notice("reset-mac requested")
    try runRelayCommand { client in
        let status = try await client.reset()
        printToolOutput(status.renderedOutput)
        printToolOutput("reset-mac: saved VPN configuration removed")
    }
}

// MARK: - Agent polling

/// Polls the agent for discovered relay services until the preferred device (or
/// any device when no name is given) appears or the timeout elapses, returning
/// the most recent snapshot either way.
private func waitForRelayServices(
    client: AgentClient,
    timeoutSeconds: Double,
    preferredName: String?
) async throws -> TunnelDiscoverySnapshot {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var latest = try await client.listRelayServices()
    while Date() < deadline {
        if relaySnapshotSatisfies(latest, preferredName: preferredName) {
            return latest
        }
        await relayPollDelay(seconds: relayPollIntervalSeconds)
        latest = try await client.listRelayServices()
    }
    return latest
}

/// Polls the agent for status until the tunnel reports running or the timeout
/// elapses, returning the most recent snapshot either way.
private func waitForTunnelRunning(
    client: AgentClient,
    timeoutSeconds: Double
) async throws -> TunnelDaemonStatusSnapshot {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var latest = try await client.status()
    while Date() < deadline {
        if latest.running {
            return latest
        }
        await relayPollDelay(seconds: relayPollIntervalSeconds)
        latest = try await client.status()
    }
    return latest
}

/// Reports whether a discovery snapshot already contains the device the caller is
/// waiting for: the named relay when a name is given, otherwise any relay.
private func relaySnapshotSatisfies(
    _ snapshot: TunnelDiscoverySnapshot,
    preferredName: String?
) -> Bool {
    guard let preferredName else {
        return !snapshot.services.isEmpty
    }
    return snapshot.services.contains { service in
        service.serviceName == preferredName
    }
}

/// Picks the relay device to select: the named one when present, otherwise the
/// first discovered device.
private func selectRelayDevice(
    from snapshot: TunnelDiscoverySnapshot,
    preferredName: String?
) -> TunnelRelayService? {
    if let preferredName {
        return snapshot.services.first { service in
            service.serviceName == preferredName
        }
    }
    return snapshot.services.first
}

/// Suspends without `Task.sleep` by resuming off a dispatch queue after the
/// interval, matching the polling cadence the rest of the project uses.
private func relayPollDelay(seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            continuation.resume()
        }
    }
}

// MARK: - Async bridge

/// Runs an async agent operation to completion from the synchronous command
/// dispatch, creating and shutting down a single AgentClient and surfacing any
/// thrown error to the caller.
func runRelayCommand(
    _ body: @escaping @Sendable (AgentClient) async throws -> Void
) throws {
    let outcome = RelayCommandOutcome()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let client = AgentClient()
        do {
            try await body(client)
        } catch {
            relayControlLogger.error(
                """
                relay command failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=rethrow-to-caller
                """
            )
            outcome.record(error)
        }
        await client.shutdown()
        semaphore.signal()
    }
    semaphore.wait()
    if let error = outcome.thrownError() {
        throw error
    }
}

/// Thread-safe holder for the error thrown inside the bridged async task so the
/// synchronous caller can rethrow it after the semaphore wakes.
private final class RelayCommandOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        storedError = error
    }

    func thrownError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

// MARK: - Argument parsing

private struct RelayUpOptions {
    let configPath: String
    let relayName: String?
    let discoverTimeoutSeconds: Double
    let connectTimeoutSeconds: Double
}

/// Parses `relay-up` options: required `--config <path>`, optional `--relay
/// <name>`, `--discover-timeout <s>`, and `--connect-timeout <s>`.
private func parseRelayUpOptions(_ arguments: [String]) throws -> RelayUpOptions {
    var configPath: String?
    var relayName: String?
    var discoverTimeoutSeconds = relayDiscoverTimeoutSeconds
    var connectTimeoutSeconds = relayConnectTimeoutSeconds

    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        let value = relayOptionValue(arguments, after: index)
        switch argument {
        case relayConfigOptionName:
            configPath = try requireRelayOptionValue(value, optionName: relayConfigOptionName)
        case relayNameOptionName:
            relayName = try requireRelayOptionValue(value, optionName: relayNameOptionName)
        case relayDiscoverTimeoutOptionName:
            discoverTimeoutSeconds = try requireRelayTimeoutValue(
                value, optionName: relayDiscoverTimeoutOptionName)
        case relayConnectTimeoutOptionName:
            connectTimeoutSeconds = try requireRelayTimeoutValue(
                value, optionName: relayConnectTimeoutOptionName)
        default:
            throw ToolError.usage("relay-up: unknown argument \(argument)")
        }
        index = arguments.index(index, offsetBy: relayOptionStride)
    }

    guard let resolvedConfigPath = configPath else {
        throw ToolError.usage("relay-up requires \(relayConfigOptionName) <path>")
    }
    return RelayUpOptions(
        configPath: (resolvedConfigPath as NSString).expandingTildeInPath,
        relayName: relayName,
        discoverTimeoutSeconds: discoverTimeoutSeconds,
        connectTimeoutSeconds: connectTimeoutSeconds)
}

/// Parses an optional `<optionName> <seconds>` pair, falling back to the default
/// when the option is absent.
private func parseRelayTimeout(
    _ arguments: [String],
    optionName: String,
    fallback: Double
) throws -> Double {
    guard let optionIndex = arguments.firstIndex(of: optionName) else {
        return fallback
    }
    let value = relayOptionValue(arguments, after: optionIndex)
    return try requireRelayTimeoutValue(value, optionName: optionName)
}

private func relayOptionValue(_ arguments: [String], after index: Int) -> String? {
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else {
        return nil
    }
    return arguments[valueIndex]
}

private func requireRelayOptionValue(_ value: String?, optionName: String) throws -> String {
    guard let value, !value.isEmpty else {
        throw ToolError.usage("missing value for \(optionName)")
    }
    return value
}

private func requireRelayTimeoutValue(_ value: String?, optionName: String) throws -> Double {
    let raw = try requireRelayOptionValue(value, optionName: optionName)
    guard let seconds = Double(raw), seconds > 0 else {
        throw ToolError.usage("\(optionName) must be a positive number of seconds")
    }
    return seconds
}

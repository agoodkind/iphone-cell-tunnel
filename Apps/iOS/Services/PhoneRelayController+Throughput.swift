import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

private let logger = CellTunnelLog.logger(category: .relay)
private let pollIntervalSeconds: Double = 1
private let providerMessageTimeoutSeconds: Double = 5
private let bitsPerByte: Double = 8
private let bitsPerMegabit: Double = 1_000_000
private let relayStoppedStateText = "Stopped"

extension PhoneRelayController {
    // Polls the extension once per second by sending a `.status` provider
    // message over the NETunnelProviderSession and mapping the decoded snapshot
    // into the Observable state the views bind. Cadence comes from awaiting the
    // round-trip plus a continuation-bridged DispatchQueue delay, never
    // Task.sleep, which the repo bans.
    func startThroughputLoop() {
        throughputTask?.cancel()
        hasSeededBaseline = false
        logger.notice("phone relay status poll starting")
        throughputTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                guard let session = self.session else {
                    await self.delayBeforeNextPoll()
                    continue
                }
                await self.pollStatus(on: session)
                guard !Task.isCancelled else {
                    return
                }
                await self.delayBeforeNextPoll()
            }
        }
    }

    func stopThroughputLoop() {
        logger.notice("phone relay status poll stopping")
        throughputTask?.cancel()
        throughputTask = nil
    }

    private func pollStatus(on session: NETunnelProviderSession) async {
        let snapshot: TunnelDaemonStatusSnapshot?
        do {
            let response = try await sendStatusRequest(on: session)
            snapshot = response.status
        } catch {
            logger.error(
                """
                phone relay status poll failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=mark-running-from-connection
                """
            )
            applyConnectionStatus(session.status)
            return
        }
        guard let snapshot else {
            logger.notice("phone relay status poll returned no status payload")
            applyConnectionStatus(session.status)
            return
        }
        apply(snapshot: snapshot, connectionStatus: session.status)
    }

    private func apply(snapshot: TunnelDaemonStatusSnapshot, connectionStatus: NEVPNStatus) {
        let polledCounters = snapshot.phoneCounters ?? TunnelCounters()
        counters = polledCounters
        cellularPath = snapshot.cellularPath ?? CellularPathSnapshot()
        connectedPeerName = snapshot.connectedPeerName
        lastError = snapshot.lastError
        relayStateDescription = snapshot.relayState ?? relayStoppedStateText
        isRunning = snapshot.running || isConnectionRunning(connectionStatus)
        updateThroughput(from: polledCounters)
    }

    private func isConnectionRunning(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    private func updateThroughput(from snapshot: TunnelCounters) {
        if !hasSeededBaseline {
            throughputBaseline = snapshot
            hasSeededBaseline = true
            return
        }
        let bytesInDelta = snapshot.relayBytesIn &- throughputBaseline.relayBytesIn
        let bytesOutDelta = snapshot.relayBytesOut &- throughputBaseline.relayBytesOut
        uploadMbps = Double(bytesInDelta) * bitsPerByte / bitsPerMegabit
        downloadMbps = Double(bytesOutDelta) * bitsPerByte / bitsPerMegabit
        logThroughputDelta(snapshot)
        throughputBaseline = snapshot
    }

    private func sendStatusRequest(
        on session: NETunnelProviderSession
    ) async throws -> ProviderControlResponse {
        let payload = try JSONEncoder().encode(ProviderControlEnvelope(request: .status))
        let responseData = try await sendProviderMessage(payload, on: session)
        return try JSONDecoder().decode(ProviderControlResponse.self, from: responseData)
    }

    // Mirrors the macOS AgentTunnelController sendProviderMessage helper: it
    // bridges the Objective-C completion callback into async/await with a single
    // resume guarded by a lock plus a timeout so a silent extension cannot hang
    // the poll loop forever.
    private func sendProviderMessage(
        _ payload: Data,
        on session: NETunnelProviderSession
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let box = ProviderMessageContinuationBox(continuation: continuation)
            do {
                try session.sendProviderMessage(payload) { response in
                    box.resume(with: response)
                }
            } catch {
                logger.error(
                    """
                    phone relay status provider message send failed \
                    details=\(String(describing: error), privacy: .public) \
                    recovery=resume-continuation-with-error
                    """
                )
                box.resumeOnce(throwing: error)
            }
            box.scheduleTimeout(providerMessageTimeoutSeconds)
        }
    }

    // Spaces polls without Task.sleep by resuming off a DispatchQueue after the
    // configured interval; the loop awaits this continuation between requests.
    private func delayBeforeNextPoll() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + pollIntervalSeconds) {
                    continuation.resume()
                }
        }
    }

    private func logThroughputDelta(_ snapshot: TunnelCounters) {
        let datagramsFromMac =
            snapshot.wireGuardDatagramsFromMac &- throughputBaseline.wireGuardDatagramsFromMac
        let datagramsToServer =
            snapshot.wireGuardDatagramsToServer &- throughputBaseline.wireGuardDatagramsToServer
        let datagramsFromServer =
            snapshot.wireGuardDatagramsFromServer &- throughputBaseline.wireGuardDatagramsFromServer
        let datagramsToMac =
            snapshot.wireGuardDatagramsToMac &- throughputBaseline.wireGuardDatagramsToMac
        let bytesIn = snapshot.relayBytesIn &- throughputBaseline.relayBytesIn
        let bytesOut = snapshot.relayBytesOut &- throughputBaseline.relayBytesOut

        if datagramsFromMac == 0, datagramsToMac == 0, bytesIn == 0, bytesOut == 0 {
            return
        }
        logger.notice(
            """
            phone relay throughput \
            datagrams_from_mac=\(datagramsFromMac, privacy: .public) \
            datagrams_to_server=\(datagramsToServer, privacy: .public) \
            datagrams_from_server=\(datagramsFromServer, privacy: .public) \
            datagrams_to_mac=\(datagramsToMac, privacy: .public) \
            bytes_relay_in=\(bytesIn, privacy: .public) \
            bytes_relay_out=\(bytesOut, privacy: .public)
            """
        )
    }
}

// Thread-safe one-shot bridge from the sendProviderMessage callback or the
// timeout into a single continuation resume, matching the macOS agent box.
private final class ProviderMessageContinuationBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var finished = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(with response: Data?) {
        guard let response else {
            resumeOnce(
                throwing: TunnelDaemonError.transportFailure(
                    "extension returned no payload for status"
                )
            )
            return
        }
        resumeOnce(returning: response)
    }

    func scheduleTimeout(_ timeoutSeconds: Double) {
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.resumeOnce(
                    throwing: TunnelDaemonError.transportFailure("extension message timed out")
                )
            }
    }

    func resumeOnce(returning value: Data) {
        guard claim() else {
            return
        }
        continuation.resume(returning: value)
    }

    func resumeOnce(throwing error: Error) {
        guard claim() else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished {
            return false
        }
        finished = true
        return true
    }
}

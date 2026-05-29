import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .relay)
private let throughputInterval: Duration = .seconds(1)
private let bitsPerByte: Double = 8
private let bitsPerMegabit: Double = 1_000_000

extension PhoneRelayController {
    func startThroughputLoop() {
        throughputTask?.cancel()
        throughputBaseline = forwarder.metrics.snapshot()
        logger.notice("phone relay throughput loop starting")
        throughputTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: throughputInterval)
                } catch {
                    logger.notice(
                        "phone relay throughput loop sleep interrupted recovery=exit-loop"
                    )
                    return
                }
                guard !Task.isCancelled, let self else {
                    return
                }
                let snapshot = forwarder.metrics.snapshot()
                counters = snapshot
                let bytesInDelta = snapshot.relayBytesIn &- throughputBaseline.relayBytesIn
                let bytesOutDelta = snapshot.relayBytesOut &- throughputBaseline.relayBytesOut
                uploadMbps = Double(bytesInDelta) * bitsPerByte / bitsPerMegabit
                downloadMbps = Double(bytesOutDelta) * bitsPerByte / bitsPerMegabit
                logThroughputDelta(snapshot)
                throughputBaseline = snapshot
            }
        }
    }

    func stopThroughputLoop() {
        logger.notice("phone relay throughput loop stopping")
        throughputTask?.cancel()
        throughputTask = nil
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

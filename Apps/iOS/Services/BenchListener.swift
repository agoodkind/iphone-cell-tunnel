import CellTunnelLog
import Foundation
import Network

public let benchModeLaunchArgument = "--cell-tunnel-bench-mode"
public let benchListenerDefaultPort: UInt16 = 51_822
public let benchBonjourServiceType = "_celltunnelbench._udp"

private let logger = CellTunnelLog.logger(category: .relay)

public final class BenchListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.goodkind.celltunnel.bench")
    private let port: UInt16
    private var listener: NWListener?
    private var receivedBytes: UInt64 = 0
    private var lastSampleBytes: UInt64 = 0
    private var lastSampleAt = Date()
    private var sampleTimer: DispatchSourceTimer?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(port: UInt16 = benchListenerDefaultPort) {
        self.port = port
    }

    public func start() {
        queue.async { [weak self] in
            self?.startInternal()
        }
    }

    private func startInternal() {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        guard let bindPort = NWEndpoint.Port(rawValue: port) else {
            logger.error("bench listener invalid port=\(self.port, privacy: .public)")
            return
        }
        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters, on: bindPort)
        } catch {
            logger.error(
                """
                bench listener create failed \
                error=\(String(describing: error), privacy: .public)
                """
            )
            return
        }
        nwListener.service = NWListener.Service(
            name: "CellTunnelBench",
            type: benchBonjourServiceType
        )
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(connection)
        }
        nwListener.stateUpdateHandler = { state in
            logger.notice(
                "bench listener state=\(String(describing: state), privacy: .public)"
            )
        }
        nwListener.start(queue: queue)
        listener = nwListener
        startSamplerLoop()
        logger.notice(
            "bench listener started port=\(self.port, privacy: .public)"
        )
    }

    private func acceptConnection(_ connection: NWConnection) {
        logger.notice("bench listener accepted connection")
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeValue(forKey: identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                receivedBytes &+= UInt64(data.count)
            }
            if error == nil {
                receiveLoop(connection)
            }
        }
    }

    private func startSamplerLoop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.sampleAndLog()
        }
        timer.resume()
        sampleTimer = timer
        lastSampleAt = Date()
    }

    private func sampleAndLog() {
        let now = Date()
        let delta = receivedBytes &- lastSampleBytes
        let seconds = max(now.timeIntervalSince(lastSampleAt), 0.001)
        let mbps = Double(delta) * 8 / seconds / 1_000_000
        logger.notice(
            """
            bench rx mbps=\(String(format: "%.2f", mbps), privacy: .public) \
            bytes_delta=\(delta, privacy: .public)
            """
        )
        lastSampleBytes = receivedBytes
        lastSampleAt = now
    }
}

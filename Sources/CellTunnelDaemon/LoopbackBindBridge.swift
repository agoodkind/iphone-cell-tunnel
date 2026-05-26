import CellTunnelLog
import Darwin
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

enum LoopbackBindBridgeError: LocalizedError {
    case socketCreateFailed(Int32)
    case socketBindFailed(Int32)
    case socketNameFailed(Int32)
    case alreadyStarted

    var errorDescription: String? {
        switch self {
        case .socketCreateFailed(let code):
            return "loopback bridge socket create failed errno=\(code)"
        case .socketBindFailed(let code):
            return "loopback bridge socket bind failed errno=\(code)"
        case .socketNameFailed(let code):
            return "loopback bridge getsockname failed errno=\(code)"
        case .alreadyStarted:
            return "loopback bridge already started"
        }
    }
}

private final class LoopbackPeerAddressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: sockaddr_in?

    func store(_ address: sockaddr_in) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value != nil {
            return false
        }
        value = address
        return true
    }

    func load() -> sockaddr_in? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

actor LoopbackBindBridge {
    private let socketFd: Int32
    private let port: UInt16
    private let pumpQueue = DispatchQueue(label: "io.goodkind.celltunneld.loopback")
    private let peerAddress = LoopbackPeerAddressBox()
    private var readSource: DispatchSourceRead?
    private weak var relay: RelayTransport?
    private var didStart = false
    private var didStop = false

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw LoopbackBindBridgeError.socketCreateFailed(errno)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bindStatus = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0 else {
            let saved = errno
            close(fd)
            throw LoopbackBindBridgeError.socketBindFailed(saved)
        }

        var assigned = sockaddr_in()
        var assignedLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &assignedLen)
            }
        }
        guard nameStatus == 0 else {
            let saved = errno
            close(fd)
            throw LoopbackBindBridgeError.socketNameFailed(saved)
        }

        self.socketFd = fd
        self.port = UInt16(bigEndian: assigned.sin_port)

        logger.notice(
            "loopback bridge bound fd=\(fd, privacy: .public) port=\(self.port, privacy: .public)"
        )
    }

    nonisolated var loopbackEndpoint: (host: String, port: UInt16) {
        ("127.0.0.1", port)
    }

    func start(relay: RelayTransport) throws {
        guard !didStart else {
            throw LoopbackBindBridgeError.alreadyStarted
        }
        didStart = true
        self.relay = relay

        let capturedFd = socketFd
        let source = DispatchSource.makeReadSource(fileDescriptor: capturedFd, queue: pumpQueue)
        source.setEventHandler { [weak self] in
            self?.drainOutbound(fd: capturedFd)
        }
        source.setCancelHandler { [weak self] in
            self?.handleCancel(fd: capturedFd)
        }
        readSource = source

        relay.onReceive = { [weak self] datagram in
            self?.writeInbound(datagram)
        }

        source.resume()
        logger.notice(
            "loopback bridge pump started port=\(self.port, privacy: .public)"
        )
    }

    func stop() {
        guard !didStop else {
            return
        }
        didStop = true
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else {
            close(socketFd)
        }
        if let activeRelay = relay {
            activeRelay.onReceive = nil
        }
        relay = nil
        logger.notice("loopback bridge stopped")
    }

    nonisolated private func drainOutbound(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBufferPointer { bufferPtr -> ssize_t in
                guard let base = bufferPtr.baseAddress else {
                    return -1
                }
                return withUnsafeMutablePointer(to: &from) { fromPtr in
                    fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        recvfrom(fd, base, bufferPtr.count, 0, sockPtr, &fromLen)
                    }
                }
            }
            if received < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR {
                    return
                }
                logger.error(
                    "loopback bridge recv failed errno=\(code, privacy: .public)"
                )
                return
            }
            if received == 0 {
                return
            }

            recordPeerAddress(from)

            let datagram = Data(bytes: buffer, count: Int(received))
            forwardToRelay(datagram)
        }
    }

    nonisolated private func forwardToRelay(_ datagram: Data) {
        let bridge = self
        Task { await bridge.sendViaRelay(datagram) }
    }

    private func sendViaRelay(_ datagram: Data) {
        relay?.send(datagram)
    }

    nonisolated private func recordPeerAddress(_ address: sockaddr_in) {
        if peerAddress.store(address) {
            logger.notice(
                """
                loopback bridge captured peer port=\
                \(UInt16(bigEndian: address.sin_port), privacy: .public)
                """
            )
        }
    }

    nonisolated private func currentPeerAddress() -> sockaddr_in? {
        peerAddress.load()
    }

    nonisolated private func writeInbound(_ datagram: Data) {
        guard var destination = currentPeerAddress() else {
            logger.error("loopback bridge inbound dropped: no peer address yet")
            return
        }
        let fd = socketFd
        let sent = datagram.withUnsafeBytes { rawBuffer -> ssize_t in
            guard let base = rawBuffer.baseAddress else {
                return -1
            }
            return withUnsafePointer(to: &destination) { destPtr in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(
                        fd,
                        base,
                        rawBuffer.count,
                        0,
                        sockPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        if sent < 0 {
            logger.error(
                "loopback bridge send failed errno=\(errno, privacy: .public)"
            )
        }
    }

    nonisolated private func handleCancel(fd: Int32) {
        close(fd)
        logger.notice("loopback bridge fd closed fd=\(fd, privacy: .public)")
    }
}

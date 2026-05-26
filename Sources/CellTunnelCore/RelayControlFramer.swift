import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .relay)

public final class RelayControlFramer: NWProtocolFramerImplementation {
    public static let definition = NWProtocolFramer.Definition(
        implementation: RelayControlFramer.self
    )
    public static let label = "RelayControl"

    private static let lengthPrefixBytes = 4

    public init(framer _: NWProtocolFramer.Instance) {
        // No per-instance state.
    }

    public func start(framer _: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        .ready
    }

    public func wakeup(framer _: NWProtocolFramer.Instance) {
        // No timers to wake.
    }

    public func stop(framer _: NWProtocolFramer.Instance) -> Bool {
        true
    }

    public func cleanup(framer _: NWProtocolFramer.Instance) {
        // No resources to release.
    }

    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var lengthBuffer = [UInt8](repeating: 0, count: Self.lengthPrefixBytes)
            let parsed = framer.parseInput(
                minimumIncompleteLength: Self.lengthPrefixBytes,
                maximumLength: Self.lengthPrefixBytes
            ) { buffer, _ -> Int in
                guard let buffer, buffer.count >= Self.lengthPrefixBytes else {
                    return 0
                }
                for index in 0..<Self.lengthPrefixBytes {
                    lengthBuffer[index] = buffer[index]
                }
                return Self.lengthPrefixBytes
            }
            guard parsed else {
                return Self.lengthPrefixBytes
            }

            let payloadLength = Int(
                (UInt32(lengthBuffer[0]) << 24)
                    | (UInt32(lengthBuffer[1]) << 16)
                    | (UInt32(lengthBuffer[2]) << 8)
                    | UInt32(lengthBuffer[3])
            )
            guard payloadLength > 0, payloadLength <= RelayControlMessageCodec.maxPayloadBytes
            else {
                logger.error(
                    "control framer rejected payloadLength=\(payloadLength, privacy: .public) recovery=mark-failed"
                )
                framer.markFailed(error: NWError.posix(.EBADMSG))
                return 0
            }

            let message = NWProtocolFramer.Message(definition: Self.definition)
            let delivered = framer.deliverInputNoCopy(
                length: payloadLength,
                message: message,
                isComplete: true
            )
            if !delivered {
                return Self.lengthPrefixBytes + payloadLength
            }
        }
    }

    public func handleOutput(
        framer: NWProtocolFramer.Instance,
        message _: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete _: Bool
    ) {
        var header = [UInt8](repeating: 0, count: Self.lengthPrefixBytes)
        let unsignedLength = UInt32(messageLength)
        header[0] = UInt8((unsignedLength >> 24) & 0xff)
        header[1] = UInt8((unsignedLength >> 16) & 0xff)
        header[2] = UInt8((unsignedLength >> 8) & 0xff)
        header[3] = UInt8(unsignedLength & 0xff)
        framer.writeOutput(data: Data(header))
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            logger.error(
                """
                control framer writeOutputNoCopy failed \
                error=\(error.localizedDescription, privacy: .public) recovery=mark-failed
                """
            )
            let nwError = (error as? NWError) ?? NWError.posix(.EIO)
            framer.markFailed(error: nwError)
        }
    }
}

public enum RelayControlFramerSupport {
    public static func framerOptions() -> NWProtocolFramer.Options {
        NWProtocolFramer.Options(definition: RelayControlFramer.definition)
    }
}

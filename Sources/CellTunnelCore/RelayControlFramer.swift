//
//  RelayControlFramer.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

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
    private static let bitsPerByte = 8
    private static let byteMask: UInt32 = 0xff

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

            var payloadLength = 0
            for byte in lengthBuffer {
                payloadLength = (payloadLength << Self.bitsPerByte) | Int(byte)
            }
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
        for index in 0..<Self.lengthPrefixBytes {
            let shift = (Self.lengthPrefixBytes - 1 - index) * Self.bitsPerByte
            header[index] = UInt8((unsignedLength >> UInt32(shift)) & Self.byteMask)
        }
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

// MARK: - RelayControlFramerSupport

public enum RelayControlFramerSupport {
    public static func framerOptions() -> NWProtocolFramer.Options {
        NWProtocolFramer.Options(definition: RelayControlFramer.definition)
    }
}

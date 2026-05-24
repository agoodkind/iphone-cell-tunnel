import Foundation

public enum RelayAddressFamily: UInt8, CaseIterable, Codable, Sendable {
    case ipv4 = 4
    case ipv6 = 6
}

public enum RelayOperation: UInt8, CaseIterable, Codable, Sendable {
    case hello = 1
    case pairConfirm = 2
    case pathStatus = 40
    case wireGuardDatagram = 50
    case error = 250
    case stats = 251
}

public struct RelayEndpoint: Codable, Equatable, Sendable {
    public var addressFamily: RelayAddressFamily
    public var host: String
    public var port: UInt16

    public init(addressFamily: RelayAddressFamily, host: String, port: UInt16) {
        self.addressFamily = addressFamily
        self.host = host
        self.port = port
    }
}

public struct RelayFrame: Codable, Equatable, Sendable {
    public static let currentVersion: UInt8 = 1

    public var version: UInt8
    public var streamID: UInt64
    public var operation: RelayOperation
    public var addressFamily: RelayAddressFamily
    public var flags: UInt16
    public var payload: Data

    public init(
        streamID: UInt64,
        operation: RelayOperation,
        addressFamily: RelayAddressFamily,
        flags: UInt16 = 0,
        payload: Data = Data(),
        version: UInt8 = RelayFrame.currentVersion
    ) {
        self.version = version
        self.streamID = streamID
        self.operation = operation
        self.addressFamily = addressFamily
        self.flags = flags
        self.payload = payload
    }
}

public struct RelayHandshakePayload: Codable, Equatable, Sendable {
    public var wireGuardServer: RelayEndpoint

    public init(wireGuardServer: RelayEndpoint) {
        self.wireGuardServer = wireGuardServer
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> RelayHandshakePayload {
        try JSONDecoder().decode(RelayHandshakePayload.self, from: data)
    }
}

public enum WireGuardDatagramError: Error, Equatable {
    case emptyDatagram
    case unexpectedOperation(RelayOperation)
}

public struct WireGuardDatagram: Equatable, Sendable {
    public var addressFamily: RelayAddressFamily
    public var data: Data

    public init(data: Data, addressFamily: RelayAddressFamily) throws {
        guard !data.isEmpty else {
            throw WireGuardDatagramError.emptyDatagram
        }

        self.addressFamily = addressFamily
        self.data = data
    }

    public init(frame: RelayFrame) throws {
        guard frame.operation == .wireGuardDatagram else {
            throw WireGuardDatagramError.unexpectedOperation(frame.operation)
        }

        try self.init(data: frame.payload, addressFamily: frame.addressFamily)
    }

    public func relayFrame(streamID: UInt64, flags: UInt16 = 0) -> RelayFrame {
        RelayFrame(
            streamID: streamID,
            operation: .wireGuardDatagram,
            addressFamily: addressFamily,
            flags: flags,
            payload: data
        )
    }
}

public enum RelayCodecError: Error, Equatable {
    case frameTooShort
    case unsupportedVersion(UInt8)
    case unknownOperation(UInt8)
    case unknownAddressFamily(UInt8)
    case payloadLengthMismatch(expected: UInt32, actual: Int)
}

public enum RelayCodec {
    public static let headerLength = 17

    public static func encode(_ frame: RelayFrame) -> Data {
        var data = Data()
        data.append(frame.version)
        data.append(frame.operation.rawValue)
        data.append(frame.addressFamily.rawValue)
        data.append(contentsOf: bigEndianBytes(frame.flags))
        data.append(contentsOf: bigEndianBytes(frame.streamID))
        let payloadLength = UInt32(frame.payload.count)
        data.append(contentsOf: bigEndianBytes(payloadLength))
        data.append(frame.payload)
        return data
    }

    public static func declaredPayloadLength(in data: Data) throws -> UInt32 {
        guard data.count >= headerLength else {
            throw RelayCodecError.frameTooShort
        }

        let version = data[0]
        guard version == RelayFrame.currentVersion else {
            throw RelayCodecError.unsupportedVersion(version)
        }

        return integer(bigEndianBytes: data[13..<17])
    }

    public static func decode(_ data: Data) throws -> RelayFrame {
        guard data.count >= headerLength else {
            throw RelayCodecError.frameTooShort
        }

        let version = data[0]
        guard version == RelayFrame.currentVersion else {
            throw RelayCodecError.unsupportedVersion(version)
        }

        let operationValue = data[1]
        guard let operation = RelayOperation(rawValue: operationValue) else {
            throw RelayCodecError.unknownOperation(operationValue)
        }

        let addressFamilyValue = data[2]
        guard let addressFamily = RelayAddressFamily(rawValue: addressFamilyValue) else {
            throw RelayCodecError.unknownAddressFamily(addressFamilyValue)
        }

        let flags: UInt16 = integer(bigEndianBytes: data[3..<5])
        let streamID: UInt64 = integer(bigEndianBytes: data[5..<13])
        let payloadLength: UInt32 = integer(bigEndianBytes: data[13..<17])
        let payload = data.dropFirst(headerLength)
        guard payload.count == Int(payloadLength) else {
            throw RelayCodecError.payloadLengthMismatch(
                expected: payloadLength,
                actual: payload.count
            )
        }

        return RelayFrame(
            streamID: streamID,
            operation: operation,
            addressFamily: addressFamily,
            flags: flags,
            payload: Data(payload),
            version: version
        )
    }

    private static func bigEndianBytes<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { bytes in
            Array(bytes)
        }
    }

    private static func integer<Value: FixedWidthInteger, Bytes: DataProtocol>(
        bigEndianBytes bytes: Bytes
    ) -> Value where Bytes.Element == UInt8 {
        var value: Value = 0
        for byte in bytes {
            value <<= 8
            value |= Value(byte)
        }
        return value
    }
}

public struct RelayFrameBuffer: Sendable {
    private var storage = Data()

    public init() {
        // The buffer intentionally starts empty and accumulates partial frames.
    }

    public mutating func append(_ data: Data) throws -> [RelayFrame] {
        storage.append(data)
        return try drainFrames()
    }

    private mutating func drainFrames() throws -> [RelayFrame] {
        var frames: [RelayFrame] = []
        while storage.count >= RelayCodec.headerLength {
            let payloadLength = try RelayCodec.declaredPayloadLength(in: storage)
            let frameLength = RelayCodec.headerLength + Int(payloadLength)
            guard storage.count >= frameLength else {
                break
            }

            let frameData = Data(storage.prefix(frameLength))
            frames.append(try RelayCodec.decode(frameData))
            storage.removeFirst(frameLength)
        }

        return frames
    }
}

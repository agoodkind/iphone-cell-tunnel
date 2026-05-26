import Foundation

public enum RelayAddressFamily: UInt8, CaseIterable, Codable, Sendable {
    case ipv4 = 4
    case ipv6 = 6
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

public enum WireGuardDatagramError: Error, Equatable {
    case emptyDatagram
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
}

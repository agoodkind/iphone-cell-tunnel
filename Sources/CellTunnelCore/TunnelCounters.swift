public struct TunnelCounters: Codable, Equatable, Sendable {
    public var wireGuardDatagramsFromMac: UInt64
    public var wireGuardDatagramsToMac: UInt64
    public var wireGuardDatagramsToServer: UInt64
    public var wireGuardDatagramsFromServer: UInt64
    public var droppedWireGuardDatagrams: UInt64
    public var relayBytesIn: UInt64
    public var relayBytesOut: UInt64

    public init(
        wireGuardDatagramsFromMac: UInt64 = 0,
        wireGuardDatagramsToMac: UInt64 = 0,
        wireGuardDatagramsToServer: UInt64 = 0,
        wireGuardDatagramsFromServer: UInt64 = 0,
        droppedWireGuardDatagrams: UInt64 = 0,
        relayBytesIn: UInt64 = 0,
        relayBytesOut: UInt64 = 0
    ) {
        self.wireGuardDatagramsFromMac = wireGuardDatagramsFromMac
        self.wireGuardDatagramsToMac = wireGuardDatagramsToMac
        self.wireGuardDatagramsToServer = wireGuardDatagramsToServer
        self.wireGuardDatagramsFromServer = wireGuardDatagramsFromServer
        self.droppedWireGuardDatagrams = droppedWireGuardDatagrams
        self.relayBytesIn = relayBytesIn
        self.relayBytesOut = relayBytesOut
    }
}

public struct CellularPathSnapshot: Codable, Equatable, Sendable {
    public var isSatisfied: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    public var interfaceName: String?
    public var interfaceIndex: Int?

    public init(
        isSatisfied: Bool = false,
        supportsIPv4: Bool = false,
        supportsIPv6: Bool = false,
        interfaceName: String? = nil,
        interfaceIndex: Int? = nil
    ) {
        self.isSatisfied = isSatisfied
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
    }
}

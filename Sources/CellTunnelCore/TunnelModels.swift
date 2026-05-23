public struct TunnelCounters: Codable, Equatable, Sendable {
    public var tcpFlows: Int
    public var udpFlows: Int
    public var icmpFlows: Int
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(
        tcpFlows: Int = 0,
        udpFlows: Int = 0,
        icmpFlows: Int = 0,
        bytesIn: UInt64 = 0,
        bytesOut: UInt64 = 0
    ) {
        self.tcpFlows = tcpFlows
        self.udpFlows = udpFlows
        self.icmpFlows = icmpFlows
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
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

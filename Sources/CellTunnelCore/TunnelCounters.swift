//
//  TunnelCounters.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

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

// MARK: - CellularPathSnapshot

/// One reading of the iPhone cellular egress path. The support flags and interface
/// identity come from the Network framework path on the iPhone. The address strings
/// are the iPhone's own cellular interface addresses, shown under the `DEVICE`
/// `Cellular` group on the status screen.
public struct CellularPathSnapshot: Codable, Equatable, Sendable {
  public var isSatisfied: Bool
  public var supportsIPv4: Bool
  public var supportsIPv6: Bool
  public var interfaceName: String?
  public var interfaceIndex: Int?
  /// The device egress interface IPv4 address, or `nil` when not yet surfaced by
  /// the path source.
  public var ipv4Address: String?
  /// The device egress interface IPv6 address, or `nil` when not yet surfaced by
  /// the path source.
  public var ipv6Address: String?
  /// The egress transport by defined name, derived from the interface type, such
  /// as `Cellular` on a device or `Wi-Fi` in the simulator.
  public var transportDisplayName: String?

  public init(
    isSatisfied: Bool = false,
    supportsIPv4: Bool = false,
    supportsIPv6: Bool = false,
    interfaceName: String? = nil,
    interfaceIndex: Int? = nil,
    ipv4Address: String? = nil,
    ipv6Address: String? = nil,
    transportDisplayName: String? = nil
  ) {
    self.isSatisfied = isSatisfied
    self.supportsIPv4 = supportsIPv4
    self.supportsIPv6 = supportsIPv6
    self.interfaceName = interfaceName
    self.interfaceIndex = interfaceIndex
    self.ipv4Address = ipv4Address
    self.ipv6Address = ipv6Address
    self.transportDisplayName = transportDisplayName
  }

  /// Maps a shared egress reading to the status snapshot, renaming the address pair
  /// into the per-family fields. Both the iPhone cellular observer and the Mac agent
  /// build their `Device` rows through this one mapping.
  public init(egress: EgressPath) {
    self.init(
      isSatisfied: egress.isSatisfied,
      supportsIPv4: egress.supportsIPv4,
      supportsIPv6: egress.supportsIPv6,
      interfaceName: egress.interfaceName,
      interfaceIndex: egress.interfaceIndex,
      ipv4Address: egress.addresses.ipv4,
      ipv6Address: egress.addresses.ipv6,
      transportDisplayName: egress.transportDisplayName
    )
  }
}

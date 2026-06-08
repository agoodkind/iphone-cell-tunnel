//
//  AddressPrefix.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - AddressFamily

/// The IP address family for a routed address prefix.
public enum AddressFamily: String, Sendable {
  case ipv4
  case ipv6
}

// MARK: - AddressPrefix

/// A CIDR address prefix parsed from a WireGuard configuration.
public struct AddressPrefix: Sendable, Equatable {
  public let family: AddressFamily
  public let address: String
  public let prefixLength: Int

  /// Creates an address prefix with its address family and prefix length.
  public init(family: AddressFamily, address: String, prefixLength: Int) {
    self.family = family
    self.address = address
    self.prefixLength = prefixLength
  }
}

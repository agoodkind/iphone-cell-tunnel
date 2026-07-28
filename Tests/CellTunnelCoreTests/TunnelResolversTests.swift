//
//  TunnelResolversTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-28.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

@Suite("Publishable resolvers")
struct TunnelResolversTests {
  /// A configuration that names no resolver gets none. Substituting one decides
  /// where a person's queries go on their behalf.
  @Test("naming no resolver publishes none")
  func namingNonePublishesNone() {
    let published = publishableResolvers(
      named: [], tunnelCarriesIPv4: true, tunnelCarriesIPv6: true)
    #expect(published.isEmpty)
  }

  @Test("both families named and carried are both published")
  func bothNamedAndCarried() {
    let published = publishableResolvers(
      named: ["10.250.10.1", "3d06:bad:b01:a::1"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: true)
    #expect(published == ["10.250.10.1", "3d06:bad:b01:a::1"])
  }

  /// A resolver the tunnel cannot reach has no source address to be answered from,
  /// so its queries would leave over a physical interface.
  @Test("a resolver for an uncarried family is dropped")
  func uncarriedFamilyIsDropped() {
    let published = publishableResolvers(
      named: ["10.250.10.1", "3d06:bad:b01:a::1"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: false)
    #expect(published == ["10.250.10.1"])
  }

  @Test("naming only an uncarried family publishes none")
  func onlyUncarriedFamilyPublishesNone() {
    let published = publishableResolvers(
      named: ["3d06:bad:b01:a::1"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: false)
    #expect(published.isEmpty)
  }

  /// Order is the configuration's preference, so it survives filtering.
  @Test("the configuration's order survives")
  func orderSurvives() {
    let published = publishableResolvers(
      named: ["1.1.1.1", "8.8.8.8", "9.9.9.9"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: true)
    #expect(published == ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
  }

  /// A value that parses as neither family is not something to publish blindly.
  @Test("an unparseable entry is dropped")
  func unparseableEntryIsDropped() {
    let published = publishableResolvers(
      named: ["not-an-address", "1.1.1.1"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: true)
    #expect(published == ["1.1.1.1"])
  }
}

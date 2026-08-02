//
//  RelayDialTargetTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - RelayDialTargetTests

/// Covers which discovered Mac the iPhone dials. Abstaining while several are visible
/// is the point of the rule, so it is the case that must not regress.
struct RelayDialTargetTests {
  private func service(id: String) -> TunnelRelayService {
    TunnelRelayService(
      id: id,
      serviceName: id,
      serviceType: "_cellrelaycontrol._tcp",
      domain: "local",
      interfaceIndex: 0,
      hostName: "\(id).local",
      endpoints: [],
      preferredEndpoint: nil,
      isSelected: false
    )
  }

  @Test func dialsNothingWhenNothingDiscovered() {
    #expect(relayDialTarget(selectedServiceID: nil, services: []) == nil)
  }

  @Test func dialsTheLoneDiscoveredMac() {
    let target = relayDialTarget(selectedServiceID: nil, services: [service(id: "a")])

    #expect(target == "a")
  }

  @Test func abstainsWhenSeveralMacsAreVisible() {
    // Two Macs and no standing choice: only the person can say which one carries their
    // traffic, so nothing dials.
    let target = relayDialTarget(
      selectedServiceID: nil,
      services: [service(id: "a"), service(id: "b")]
    )

    #expect(target == nil)
  }

  @Test func keepsTheStandingSelectionWhileItIsStillVisible() {
    let target = relayDialTarget(
      selectedServiceID: "b",
      services: [service(id: "a"), service(id: "b")]
    )

    #expect(target == "b")
  }

  @Test func abstainsWhenTheStandingSelectionDisappearsAmongSeveral() {
    // The chosen Mac went away and two others remain. Falling back to the first listed
    // is what the app's copy did, and it is what must not happen.
    let target = relayDialTarget(
      selectedServiceID: "gone",
      services: [service(id: "a"), service(id: "b")]
    )

    #expect(target == nil)
  }
}

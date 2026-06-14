//
//  StickyEgressSelectionTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - StickyEgressSelectionTests

/// Covers the pieces behind a selection that survives reconnects: the stable per-install
/// device id the iPhone sends, its round-trip in the control `Status`, and the Mac store
/// that remembers the chosen device id. Each store test uses its own scratch defaults.
struct StickyEgressSelectionTests {
  // MARK: - Scratch suite

  private func makeScratchDefaults() throws -> UserDefaults {
    let suiteName = "io.goodkind.celltunnel.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  // MARK: - Stable device id

  @Test func deviceIDIsStableAcrossCalls() throws {
    let defaults = try makeScratchDefaults()
    let first = relayServiceDeviceID(defaults: defaults)
    let second = relayServiceDeviceID(defaults: defaults)
    #expect(!first.isEmpty)
    #expect(first == second)
  }

  // MARK: - Status carries the device id

  @Test func statusDeviceIDRoundTrips() throws {
    let status = RelayControlMessage.Status(
      hasCellularPath: true,
      deviceName: "Alex iPhone",
      deviceID: "ABC-123"
    )
    let data = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(RelayControlMessage.Status.self, from: data)
    #expect(decoded.deviceID == "ABC-123")
    #expect(decoded.deviceName == "Alex iPhone")
  }

  @Test func oldStatusWithoutDeviceIDDecodesNil() throws {
    let json = """
      {"version": 1, "hasCellularPath": true}
      """
    let data = try #require(json.data(using: .utf8))
    let decoded = try JSONDecoder().decode(RelayControlMessage.Status.self, from: data)
    #expect(decoded.deviceID == nil)
    #expect(decoded.deviceName == nil)
  }

  // MARK: - Egress selection store

  @Test func unsetSelectionReadsNil() throws {
    let defaults = try makeScratchDefaults()
    #expect(EgressSelectionStore.selectedDeviceID(from: defaults) == nil)
  }

  @Test func savedSelectionRoundTrips() throws {
    let defaults = try makeScratchDefaults()
    EgressSelectionStore.setSelectedDeviceID("device-7", to: defaults)
    #expect(EgressSelectionStore.selectedDeviceID(from: defaults) == "device-7")
  }

  @Test func clearRemovesSelection() throws {
    let defaults = try makeScratchDefaults()
    EgressSelectionStore.setSelectedDeviceID("device-7", to: defaults)
    EgressSelectionStore.clear(in: defaults)
    #expect(EgressSelectionStore.selectedDeviceID(from: defaults) == nil)
  }

  @Test func settingNilClearsSelection() throws {
    let defaults = try makeScratchDefaults()
    EgressSelectionStore.setSelectedDeviceID("device-7", to: defaults)
    EgressSelectionStore.setSelectedDeviceID(nil, to: defaults)
    #expect(EgressSelectionStore.selectedDeviceID(from: defaults) == nil)
  }
}

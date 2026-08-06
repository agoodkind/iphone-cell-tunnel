//
//  RelaySituationTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-05.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RelaySituationTests

/// Covers which situation each producer reports. Neither chain had a test before, and
/// the order of the branches is the whole behavior, so each test names the pair of
/// situations whose precedence it pins.
struct RelaySituationTests {
  private func macSnapshot(
    lastError: String? = nil,
    vpnProfileState: TunnelVPNProfileState? = .enabled,
    connectedPeerName: String? = "iPhone",
    advertising: TunnelAdvertisingState? = .advertising,
    activeConfigID: UUID? = UUID(),
    routingPhase: TunnelRoutingPhase? = .idle
  ) -> TunnelDaemonStatusSnapshot {
    TunnelDaemonStatusSnapshot(
      lastError: lastError,
      connectedPeerName: connectedPeerName,
      advertising: advertising,
      routingPhase: routingPhase,
      activeConfigID: activeConfigID,
      vpnProfileState: vpnProfileState
    )
  }

  // MARK: - Mac

  @Test func macReportsFailureAboveEverythingElse() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(lastError: "boom"), hasImportedConfig: true, peersFound: true)

    #expect(situation == .failed)
  }

  /// Deleting every config leaves the profile in place, and re-enabling a profile with
  /// nothing to route accomplishes nothing, so the library comes first.
  @Test func macAsksForAConfigBeforeItAsksForTheProfile() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(vpnProfileState: .disabled),
      hasImportedConfig: false,
      peersFound: true
    )

    #expect(situation == .noConfigImported)
  }

  @Test func macAsksForTheProfileOnceAConfigExists() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(vpnProfileState: .disabled),
      hasImportedConfig: true,
      peersFound: true
    )

    #expect(situation == .vpnProfileDisabled)
  }

  @Test func macAsksForAnActiveConfigOnceAPeerIsConnected() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(activeConfigID: nil), hasImportedConfig: true, peersFound: true)

    #expect(situation == .noActiveConfig)
  }

  /// The connecting word used to be applied by the screen on top of the state, in a
  /// second place, so it is part of the situation now.
  @Test func macIsConnectingWhileRoutesAreLanding() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(routingPhase: .connecting),
      hasImportedConfig: true,
      peersFound: true
    )

    #expect(situation == .connecting)
  }

  @Test func macIsRoutingOnceRoutesAreInstalled() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(routingPhase: .routing), hasImportedConfig: true, peersFound: true)

    #expect(situation == .routing)
  }

  @Test func macIsReadyToRouteWithAPeerAndAConfig() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(), hasImportedConfig: true, peersFound: true)

    #expect(situation == .readyToRoute)
  }

  @Test func macSearchesWhenNoPeerIsListed() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(connectedPeerName: nil),
      hasImportedConfig: true,
      peersFound: false
    )

    #expect(situation == .noPeersFound)
  }

  /// Waiting and being unfindable look identical from the outside, and only one of
  /// them ends on its own, so a Mac that is not advertising says so.
  @Test func macSaysItCannotBeFoundRatherThanSearching() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(connectedPeerName: nil, advertising: .notAdvertising),
      hasImportedConfig: true,
      peersFound: false
    )

    #expect(situation == .notDiscoverable)
  }

  @Test func macAsksForAPeerWhenOneIsListedButNotConnected() {
    let situation = macRelaySituation(
      snapshot: macSnapshot(connectedPeerName: nil),
      hasImportedConfig: true,
      peersFound: true
    )

    #expect(situation == .noPeerSelected)
  }

  // MARK: - iPhone

  @Test func phoneAsksToInstallTheTunnelFirst() {
    let situation = phoneRelaySituation(
      snapshot: TunnelDaemonStatusSnapshot(peerState: .notSelected), peersFound: true)

    #expect(situation == .notProvisioned)
  }

  @Test func phoneIsRoutingOnceRoutesAreInstalled() {
    let snapshot = TunnelDaemonStatusSnapshot(
      peerState: .wireGuardConfigured,
      connectedPeerName: "Mac",
      routingPhase: .routing
    )

    #expect(phoneRelaySituation(snapshot: snapshot, peersFound: true) == .routing)
  }

  /// A producer that predates the phase still splits routing from ready by whether the
  /// routes are installed, which is what the screens used to read.
  @Test func anOlderProducerFallsBackToInstalledRoutes() {
    let snapshot = TunnelDaemonStatusSnapshot(
      routeState: .installed,
      peerState: .wireGuardConfigured,
      connectedPeerName: "Mac"
    )

    #expect(phoneRelaySituation(snapshot: snapshot, peersFound: true) == .routing)
  }

  /// The iPhone installs no agent and holds no library, so those situations are not
  /// reachable from its snapshot no matter what it carries.
  @Test func phoneNeverReportsAMacOnlySituation() {
    let snapshot = TunnelDaemonStatusSnapshot(
      peerState: .wireGuardConfigured, connectedPeerName: "Mac", activeConfigID: nil)
    let situation = phoneRelaySituation(snapshot: snapshot, peersFound: true)

    #expect(situation != .noAgent)
    #expect(situation != .noActiveConfig)
    #expect(situation != .noConfigImported)
  }

  // MARK: - Wire

  @Test func travelsOnTheWire() throws {
    let snapshot = TunnelDaemonStatusSnapshot(situation: .readyToRoute)

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: encoded)

    #expect(decoded.situation == .readyToRoute)
  }

  @Test func absentFromAnOlderProducer() {
    #expect(TunnelDaemonStatusSnapshot().situation == nil)
  }
}

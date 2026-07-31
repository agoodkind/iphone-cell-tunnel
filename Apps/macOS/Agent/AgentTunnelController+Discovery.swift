//
//  AgentTunnelController+Discovery.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Relay discovery

extension AgentTunnelController {
  /// Starts discovery in both directions and returns the current discovery snapshot.
  ///
  /// Discovery has two halves. The browser finds other devices, and the control
  /// listener publishes the record that lets an iPhone find this Mac. Starting only
  /// the browser leaves a Mac that cannot be found, which is the state a person is
  /// trying to leave when they run this. Starting the listener here is also the
  /// documented way back from a listener the agent stopped rebuilding.
  ///
  /// A listener that will not start is reported and does not fail the request, because
  /// the browser half still works and the snapshot still answers.
  func startDiscovery() async -> AgentControlResponse {
    relayBrowser.start()
    do {
      try await ensureControlListenerStarted()
    } catch {
      logger.error(
        """
        agent discovery could not start the control listener \
        details=\(String(describing: error), privacy: .public) \
        recovery=browser-only
        """
      )
    }
    logger.notice("agent relay discovery started from browser")
    return snapshotResponse()
  }

  /// Records the chosen relay service by id, or fails when no discovered relay
  /// matches, then returns the refreshed discovery snapshot.
  func selectRelay(serviceID: String) -> AgentControlResponse {
    let devices = relayBrowser.snapshot()
    guard let device = devices.first(where: { $0.identifier == serviceID }) else {
      return failure(
        errorCode: .relaySelectionRequired,
        message: "no discovered relay with id \(serviceID)"
      )
    }
    RelaySelectionStore.setSelectedRelayServiceName(device.serviceName)
    logger.notice(
      "agent selected relay service=\(device.serviceName, privacy: .public)"
    )
    return snapshotResponse()
  }

  /// Builds the discovery snapshot from the browser's current devices, flagging
  /// the selected service.
  func snapshotResponse() -> AgentControlResponse {
    let devices = relayBrowser.snapshot()
    let selectedServiceName = RelaySelectionStore.selectedRelayServiceName()
    let services = devices.map { device in
      TunnelRelayService(
        id: device.identifier,
        serviceName: device.serviceName,
        serviceType: device.serviceType,
        domain: device.domain,
        interfaceIndex: device.interfaceIndex,
        hostName: "",
        endpoints: [],
        preferredEndpoint: nil,
        isSelected: device.serviceName == selectedServiceName
      )
    }
    let selectedServiceID = devices.first { device in
      device.serviceName == selectedServiceName
    }?.identifier
    let snapshot = TunnelDiscoverySnapshot(
      phase: services.isEmpty ? .browsing : .ready,
      services: services,
      selectedServiceID: selectedServiceID
    )
    return AgentControlResponse(discovery: snapshot)
  }
}

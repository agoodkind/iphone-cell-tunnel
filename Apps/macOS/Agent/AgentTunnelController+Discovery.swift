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
  /// Starts the relay device browser and returns the current discovery snapshot.
  func startDiscovery() -> AgentControlResponse {
    relayBrowser.start()
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

//
//  AgentTunnelController+Reload.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Live reload

extension AgentTunnelController {
  /// Validates WireGuard configuration text without changing tunnel state.
  func handleValidateConfig(text: String) async -> AgentControlResponse {
    await Task.yield()
    do {
      _ = try WireGuardConfigParser.parse(text)
      return AgentControlResponse()
    } catch {
      logger.notice(
        """
        validateConfig rejected config as unparseable \
        recovery=return-invalid-response-without-logging-config
        """
      )
      return failure(errorCode: .unspecified, message: error.localizedDescription)
    }
  }

  /// Applies an edited WireGuard config to the already-running tunnel without a
  /// VPN profile save or a session restart. It reads the config file, then asks
  /// the running extension to reload it in place over the provider control
  /// channel, which reconfigures WireGuard and the captured route set live.
  func handleReloadTunnel(settings: TunnelStartSettings) async -> AgentControlResponse {
    guard settings.hasWireGuardConfigPath else {
      return failure(
        errorCode: .missingWireGuardConfigPath,
        message: "reload requires a WireGuard config path"
      )
    }
    do {
      let configText = try readConfigText(at: settings.wireGuardConfigPath)
      let manager = try await loadOrCreateManager()
      guard isSessionActive(on: manager) else {
        return failure(
          errorCode: .internal,
          message: "reload requires a running tunnel"
        )
      }
      let response = try await forward(
        request: .reloadConfig(text: configText),
        on: manager,
        operationName: "reloadConfig"
      )
      logger.notice("agent tunnel reload requested")
      if let status = response.status {
        return AgentControlResponse(status: augmented(status))
      }
      return try await forwardStatus(on: manager)
    } catch {
      logger.error(
        """
        reloadTunnel agent operation caught error \
        details=\(String(describing: error), privacy: .public) \
        recovery=return-failure-response
        """
      )
      return failure(from: error)
    }
  }
}

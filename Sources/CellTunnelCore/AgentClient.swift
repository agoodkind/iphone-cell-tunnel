//
//  AgentClient.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
@preconcurrency import XPC

#if os(macOS) || targetEnvironment(macCatalyst)
  private let logger = CellTunnelLog.logger(category: .daemon)

  /// The single control client for the agent. It connects to the agent's mach
  /// service with the modern libxpc session API, which both a native macOS
  /// program and a Mac Catalyst app can use. Each request encodes an
  /// `AgentControlEnvelope` to JSON, travels as one data field of an xpc
  /// dictionary, and the reply carries an `AgentControlResponse` JSON under the
  /// same key. The actor serializes requests so the blocking send runs off the
  /// caller's thread, which the synchronous libxpc reply call requires.
  public actor AgentClient: TunnelControlClientProtocol {
    private var session: XPCSession?

    public init(
      endpointPath: String = "",
      binaryName: String = agentBinaryName,
      environment: [String: String] = [:]
    ) {
      _ = endpointPath
      _ = binaryName
      _ = environment
    }

    public func shutdown() {
      logger.notice("agent client shutdown requested")
      tearDownSession(reason: "shutdown")
    }

    public func status() async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=status")
      let response = try await send(request: .status, operationName: "status")
      return try requireStatus(from: response, operationName: "status")
    }

    public func check() async throws -> TunnelEnvironmentReport {
      logger.notice("agent client invoked rpc=check")
      let response = try await send(request: .check, operationName: "check")
      if let failure = response.failure {
        throw mapFailure(failure)
      }
      guard let report = response.report else {
        throw TunnelDaemonError.transportFailure("missing check response payload")
      }
      return report
    }

    public func startTunnel(
      settings: TunnelStartSettings
    ) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=start-tunnel")
      let response = try await send(
        request: .startTunnel(settings),
        operationName: "startTunnel"
      )
      return try requireStatus(from: response, operationName: "startTunnel")
    }

    public func reloadTunnel(
      settings: TunnelStartSettings
    ) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=reload-tunnel")
      let response = try await send(
        request: .reloadTunnel(settings),
        operationName: "reloadTunnel"
      )
      return try requireStatus(from: response, operationName: "reloadTunnel")
    }

    /// Validates WireGuard configuration text without changing tunnel state.
    public func validateConfig(text: String) async throws {
      logger.notice("agent client invoked rpc=validate-config")
      let response = try await send(
        request: .validateConfig(text: text),
        operationName: "validateConfig"
      )
      if let failure = response.failure {
        throw mapFailure(failure)
      }
    }

    public func stopTunnel() async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=stop-tunnel")
      let response = try await send(request: .stopTunnel, operationName: "stopTunnel")
      return try requireStatus(from: response, operationName: "stopTunnel")
    }

    public func reset() async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=reset")
      let response = try await send(request: .reset, operationName: "reset")
      return try requireStatus(from: response, operationName: "reset")
    }

    public func startRelayDiscovery() async throws -> TunnelDiscoverySnapshot {
      logger.notice("agent client invoked rpc=start-relay-discovery")
      let response = try await send(
        request: .startRelayDiscovery,
        operationName: "startRelayDiscovery"
      )
      return try requireDiscovery(from: response, operationName: "startRelayDiscovery")
    }

    public func stopRelayDiscovery() async throws -> TunnelDiscoverySnapshot {
      logger.notice("agent client invoked rpc=stop-relay-discovery")
      let response = try await send(
        request: .stopRelayDiscovery,
        operationName: "stopRelayDiscovery"
      )
      return try requireDiscovery(from: response, operationName: "stopRelayDiscovery")
    }

    public func listRelayServices() async throws -> TunnelDiscoverySnapshot {
      logger.notice("agent client invoked rpc=list-relay-services")
      let response = try await send(
        request: .listRelayServices,
        operationName: "listRelayServices"
      )
      return try requireDiscovery(from: response, operationName: "listRelayServices")
    }

    public func selectRelayService(serviceID: String) async throws -> TunnelDiscoverySnapshot {
      logger.notice(
        "agent client invoked rpc=select-relay-service serviceID=\(serviceID, privacy: .public)"
      )
      let response = try await send(
        request: .selectRelayService(serviceID: serviceID),
        operationName: "selectRelayService"
      )
      return try requireDiscovery(from: response, operationName: "selectRelayService")
    }

    /// Selects which connected iPhone the agent routes egress through, by the
    /// per-connection id the roster carries, and returns the refreshed status.
    public func selectEgressPeer(peerID: String) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice(
        "agent client invoked rpc=select-egress-peer peerID=\(peerID, privacy: .public)"
      )
      let response = try await send(
        request: .selectEgressPeer(peerID: peerID),
        operationName: "selectEgressPeer"
      )
      return try requireStatus(from: response, operationName: "selectEgressPeer")
    }

    public func setRoutingEnabled(_ enabled: Bool) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice(
        "agent client invoked rpc=set-routing-enabled enabled=\(enabled, privacy: .public)")
      let response = try await send(
        request: .setRoutingEnabled(enabled: enabled),
        operationName: "setRoutingEnabled"
      )
      return try requireStatus(from: response, operationName: "setRoutingEnabled")
    }

    // MARK: - Config library

    /// Validates, stores, activates, and starts a config from its text. The text
    /// carries a `PrivateKey`, so only its length is logged.
    public func importConfig(
      name: String, text: String
    ) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice(
        "agent client invoked rpc=import-config bytes=\(text.count, privacy: .public)")
      let response = try await send(
        request: .importConfig(name: name, text: text),
        operationName: "importConfig"
      )
      return try requireStatus(from: response, operationName: "importConfig")
    }

    /// Makes a stored config active and starts the tunnel with it.
    public func activateConfig(id: String) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=activate-config id=\(id, privacy: .public)")
      let response = try await send(
        request: .activateConfig(id: id),
        operationName: "activateConfig"
      )
      return try requireStatus(from: response, operationName: "activateConfig")
    }

    /// Saves edited config text and reloads the tunnel when that config is active.
    public func saveConfigEdit(
      id: String, text: String
    ) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice(
        """
        agent client invoked rpc=save-config-edit id=\(id, privacy: .public) \
        bytes=\(text.count, privacy: .public)
        """
      )
      let response = try await send(
        request: .saveConfigEdit(id: id, text: text),
        operationName: "saveConfigEdit"
      )
      return try requireStatus(from: response, operationName: "saveConfigEdit")
    }

    /// Renames a stored config.
    public func renameConfig(id: String, name: String) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=rename-config id=\(id, privacy: .public)")
      let response = try await send(
        request: .renameConfig(id: id, name: name),
        operationName: "renameConfig"
      )
      return try requireStatus(from: response, operationName: "renameConfig")
    }

    /// Deletes a stored config, stopping the tunnel first when it is the active one.
    public func deleteConfig(id: String) async throws -> TunnelDaemonStatusSnapshot {
      logger.notice("agent client invoked rpc=delete-config id=\(id, privacy: .public)")
      let response = try await send(
        request: .deleteConfig(id: id),
        operationName: "deleteConfig"
      )
      return try requireStatus(from: response, operationName: "deleteConfig")
    }

    /// Returns the secret text of a stored config, fetched only for editing.
    public func getConfigText(id: String) async throws -> String {
      logger.notice("agent client invoked rpc=get-config-text id=\(id, privacy: .public)")
      let response = try await send(
        request: .getConfigText(id: id),
        operationName: "getConfigText"
      )
      return try requireConfigText(from: response, operationName: "getConfigText")
    }
  }

  extension AgentClient {
    private func send(
      request: AgentControlRequest,
      operationName: String
    ) throws -> AgentControlResponse {
      let payload = try encode(request: request, operationName: operationName)
      let responseData = try transmit(payload: payload, operationName: operationName)
      let response = try decode(responseData: responseData, operationName: operationName)
      try validate(responseVersion: response.version, operationName: operationName)
      logger.notice(
        "\(operationName) agent rpc completed responseVersion=\(response.version, privacy: .public)"
      )
      return response
    }

    private func encode(request: AgentControlRequest, operationName: String) throws -> Data {
      do {
        return try JSONEncoder().encode(AgentControlEnvelope(request: request))
      } catch {
        logger.error(
          """
          \(operationName) agent request encode failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=throw-transport-failure
          """
        )
        throw TunnelDaemonError.transportFailure(
          "encode \(operationName) request failed: \(error.localizedDescription)"
        )
      }
    }

    private func decode(
      responseData: Data,
      operationName: String
    ) throws -> AgentControlResponse {
      do {
        return try JSONDecoder().decode(AgentControlResponse.self, from: responseData)
      } catch {
        logger.error(
          """
          \(operationName) agent response decode failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=throw-transport-failure
          """
        )
        throw TunnelDaemonError.transportFailure(
          "decode \(operationName) response failed: \(error.localizedDescription)"
        )
      }
    }

    // Sends the request and blocks for the reply. A failed send drops the
    // session so the next request reconnects, which recovers from an agent
    // restart. The actor runs this off the caller's thread, which the
    // synchronous libxpc reply call requires.
    private func transmit(payload: Data, operationName: String) throws -> Data {
      let session = try activeSession()
      logger.notice(
        "\(operationName) agent rpc transmitting bytes=\(payload.count, privacy: .public)"
      )
      do {
        let reply = try session.sendSync(message: makeMessage(payload: payload))
        return try replyData(from: reply, operationName: operationName)
      } catch let error as TunnelDaemonError {
        logger.error(
          """
          \(operationName) agent send failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=drop-session-and-rethrow
          """
        )
        tearDownSession(reason: "send-failed")
        throw error
      } catch {
        logger.error(
          """
          \(operationName) agent send failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=drop-session-and-throw-transport-failure
          """
        )
        tearDownSession(reason: "send-failed")
        throw TunnelDaemonError.transportFailure(
          "\(operationName) agent send failed: \(error.localizedDescription)"
        )
      }
    }

    private func activeSession() throws -> XPCSession {
      if let session {
        return session
      }
      do {
        let created = try XPCSession(machService: agentMachServiceName)
        session = created
        logger.notice(
          "agent xpc session opened machServiceName=\(agentMachServiceName, privacy: .public)"
        )
        return created
      } catch {
        logger.error(
          """
          agent xpc session open failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=throw-transport-failure
          """
        )
        throw TunnelDaemonError.transportFailure(
          "open agent session failed: \(error.localizedDescription)"
        )
      }
    }

    // Writes the JSON payload as a data value on the underlying xpc dictionary,
    // matching the agent listener's data key.
    private func makeMessage(payload: Data) -> XPCDictionary {
      let raw = xpc_dictionary_create_empty()
      payload.withUnsafeBytes { rawBuffer in
        xpc_dictionary_set_data(
          raw, agentControlPayloadKey, rawBuffer.baseAddress, rawBuffer.count
        )
      }
      return XPCDictionary(raw)
    }

    private func replyData(
      from reply: XPCDictionary,
      operationName: String
    ) throws -> Data {
      let data = reply.withUnsafeUnderlyingDictionary { raw -> Data? in
        var length = 0
        guard
          let pointer = xpc_dictionary_get_data(raw, agentControlPayloadKey, &length),
          length > 0
        else {
          return nil
        }
        return Data(bytes: pointer, count: length)
      }
      guard let data else {
        throw TunnelDaemonError.transportFailure(
          "agent returned no payload for \(operationName)"
        )
      }
      return data
    }

    private func tearDownSession(reason: String) {
      guard let active = session else {
        return
      }
      active.cancel(reason: reason)
      session = nil
      logger.notice("agent xpc session torn down reason=\(reason, privacy: .public)")
    }

    private func validate(responseVersion: Int, operationName: String) throws {
      if responseVersion > agentControlWireVersion {
        logger.error(
          """
          \(operationName) agent response rejected \
          receivedVersion=\(responseVersion, privacy: .public) \
          supportedVersion=\(agentControlWireVersion, privacy: .public)
          """
        )
        throw TunnelDaemonError.transportFailure(
          "unsupported agent response version \(responseVersion)"
        )
      }
    }

    private func requireStatus(
      from response: AgentControlResponse,
      operationName: String
    ) throws -> TunnelDaemonStatusSnapshot {
      if let failure = response.failure {
        throw mapFailure(failure)
      }
      guard let status = response.status else {
        throw TunnelDaemonError.transportFailure("missing \(operationName) status payload")
      }
      return status
    }

    private func requireDiscovery(
      from response: AgentControlResponse,
      operationName: String
    ) throws -> TunnelDiscoverySnapshot {
      if let failure = response.failure {
        throw mapFailure(failure)
      }
      guard let discovery = response.discovery else {
        throw TunnelDaemonError.transportFailure(
          "missing \(operationName) discovery payload"
        )
      }
      return discovery
    }

    private func requireConfigText(
      from response: AgentControlResponse,
      operationName: String
    ) throws -> String {
      if let failure = response.failure {
        throw mapFailure(failure)
      }
      guard let configText = response.configText else {
        throw TunnelDaemonError.transportFailure(
          "missing \(operationName) config text payload"
        )
      }
      return configText
    }

    private func mapFailure(_ failure: AgentControlFailure) -> TunnelDaemonError {
      TunnelDaemonError.controlFailure(
        TunnelControlFailure(errorCode: failure.errorCode, message: failure.message)
      )
    }
  }
#endif

//
//  AgentClient+Responses.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-06.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
@preconcurrency import XPC

#if os(macOS) || targetEnvironment(macCatalyst)

  private let logger = CellTunnelLog.logger(category: .daemon)

  // MARK: - Payload coding and response reading

  /// The stateless halves of the client: turning a request into wire bytes, reading the
  /// reply back, and insisting each reply carries the payload its operation promises.
  /// They live apart from the session-owning half so neither file grows past what the
  /// lint gate allows.
  extension AgentClient {
    func encode(request: AgentControlRequest, operationName: String) throws -> Data {
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

    func decode(
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

    // Writes the JSON payload as a data value on the underlying xpc dictionary,
    // matching the agent listener's data key.
    func makeMessage(payload: Data) -> XPCDictionary {
      let raw = xpc_dictionary_create_empty()
      payload.withUnsafeBytes { rawBuffer in
        xpc_dictionary_set_data(
          raw, agentControlPayloadKey, rawBuffer.baseAddress, rawBuffer.count
        )
      }
      return XPCDictionary(raw)
    }

    /// The payload carried on one message, shared by the reply path and the pushes.
    nonisolated static func payloadData(from message: XPCDictionary) -> Data? {
      message.withUnsafeUnderlyingDictionary { raw -> Data? in
        var length = 0
        guard
          let pointer = xpc_dictionary_get_data(raw, agentControlPayloadKey, &length),
          length > 0
        else {
          return nil
        }
        return Data(bytes: pointer, count: length)
      }
    }

    func replyData(
      from reply: XPCDictionary,
      operationName: String
    ) throws -> Data {
      guard let data = Self.payloadData(from: reply) else {
        throw TunnelDaemonError.transportFailure(
          "agent returned no payload for \(operationName)"
        )
      }
      return data
    }

    func validate(responseVersion: Int, operationName: String) throws {
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

    func requireStatus(
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

    func requireDiscovery(
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

    func requireConfigText(
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

    func mapFailure(_ failure: AgentControlFailure) -> TunnelDaemonError {
      TunnelDaemonError.controlFailure(
        TunnelControlFailure(errorCode: failure.errorCode, message: failure.message)
      )
    }
  }
#endif

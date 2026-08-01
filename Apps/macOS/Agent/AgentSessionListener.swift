//
//  AgentSessionListener.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Synchronization
@preconcurrency import XPC

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - AgentSessionListener

/// Serves the agent's control protocol over the libxpc mach-service listener. It
/// is the agent's single control transport: the command-line tool and the Mac app
/// both dial it with the libxpc session API. A Mac Catalyst app cannot open an
/// `NSXPCConnection` to a mach service, so libxpc is the one transport both clients
/// share. Each request decodes an `AgentControlEnvelope` JSON and calls the
/// controller, and the reply carries an `AgentControlResponse` JSON.
final class AgentSessionListener: @unchecked Sendable {
  private let controller: AgentTunnelController
  private let subscribers: SubscriberRegistry
  private var listenerConnection: xpc_connection_t?

  init(controller: AgentTunnelController, subscribers: SubscriberRegistry) {
    self.controller = controller
    self.subscribers = subscribers
  }

  // MARK: - Lifecycle

  /// Creates the listener connection on the agent mach service and begins
  /// accepting peer connections. The name is vended by the agent launchd plist
  /// `MachServices` dict, so the lookup resolves once the agent is registered.
  func start() {
    let listener = agentMachServiceName.withCString { namePointer in
      xpc_connection_create_mach_service(
        namePointer,
        nil,
        UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
      )
    }
    listenerConnection = listener
    xpc_connection_set_event_handler(listener) { [weak self] peer in
      self?.handleIncomingPeer(peer)
    }
    xpc_connection_resume(listener)
    logger.notice(
      """
      agent session listener resumed \
      machService=\(agentMachServiceName, privacy: .public)
      """
    )
  }

  /// Cancels the listener connection so it stops accepting peers.
  func stop() {
    guard let listener = listenerConnection else {
      return
    }
    xpc_connection_cancel(listener)
    listenerConnection = nil
    logger.notice("agent session listener cancelled")
  }

  // MARK: - Peer handling

  private func handleIncomingPeer(_ peer: xpc_object_t) {
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
      logger.error(
        """
        agent session listener received non-connection event \
        recovery=ignore
        """
      )
      return
    }
    // The subscription is created with the peer and held by the peer's own event
    // handler, so it lives exactly as long as the connection does. An error event is the
    // only notice that a client is gone, so it is also the only chance to stop sending
    // into a connection nobody is reading.
    let subscription = PeerSubscription(peer: peer, registry: subscribers)
    xpc_connection_set_event_handler(peer) { [weak self] message in
      guard xpc_get_type(message) != XPC_TYPE_ERROR else {
        subscription.end()
        logger.notice("agent session listener peer connection ended")
        return
      }
      self?.handleIncomingMessage(message, on: peer, subscription: subscription)
    }
    xpc_connection_resume(peer)
    logger.notice("agent session listener accepted inbound session")
  }

  private func handleIncomingMessage(
    _ message: xpc_object_t,
    on peer: xpc_connection_t,
    subscription: PeerSubscription
  ) {
    guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
      logger.notice("agent session listener ignored non-dictionary message")
      return
    }
    // The reply dictionary and the peer are non-Sendable libxpc handles, so
    // they are captured together in one box created on this queue. The async
    // controller call crosses the actor boundary with only Sendable values
    // (the decoded request and the box), and the box sends the reply back.
    let replyChannel = ReplyChannel(peer: peer, message: message)
    guard let requestData = payloadData(from: message) else {
      logger.error(
        """
        agent session message missing payload \
        recovery=reply-failure
        """
      )
      replyChannel.sendFailure("missing request payload")
      return
    }
    let request: AgentControlRequest
    do {
      request = try JSONDecoder().decode(
        AgentControlEnvelope.self, from: requestData
      ).request
    } catch {
      logger.error(
        """
        agent session request decode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=reply-failure
        """
      )
      replyChannel.sendFailure("request decode failed")
      return
    }
    // Registering before the controller call means a snapshot pushed while the reply is
    // still being built still reaches the client that just subscribed.
    if case .subscribe = request {
      subscription.begin()
    }
    let handlingController = self.controller
    Task {
      let response = await handlingController.handle(request: request)
      replyChannel.send(response)
    }
  }

  // MARK: - Payload

  private func payloadData(from message: xpc_object_t) -> Data? {
    var length = 0
    guard let pointer = xpc_dictionary_get_data(message, agentControlPayloadKey, &length),
      length > 0
    else {
      return nil
    }
    return Data(bytes: pointer, count: length)
  }
}

// MARK: - ReplyChannel

/// Holds the non-Sendable libxpc reply handles for one request so the async
/// controller call can hand back a response without capturing `xpc_object_t`
/// across the actor boundary. The peer and the inbound message are captured on the
/// listener queue; the response or failure encodes to JSON and sends on the same
/// peer.
private final class ReplyChannel: @unchecked Sendable {
  private let peer: xpc_connection_t
  private let message: xpc_object_t

  init(peer: xpc_connection_t, message: xpc_object_t) {
    self.peer = peer
    self.message = message
  }

  func send(_ response: AgentControlResponse) {
    guard let data = encode(response) else {
      sendFailure("response encode failed")
      return
    }
    sendData(data)
  }

  func sendFailure(_ failureMessage: String) {
    let failure = AgentControlResponse(
      failure: AgentControlFailure(errorCode: .internal, message: failureMessage)
    )
    guard let data = encode(failure) else {
      logger.error("agent session failure encode failed recovery=drop-reply")
      return
    }
    sendData(data)
  }

  private func sendData(_ data: Data) {
    guard let reply = xpc_dictionary_create_reply(message) else {
      logger.error("agent session could not create reply dictionary recovery=drop-reply")
      return
    }
    data.withUnsafeBytes { rawBuffer in
      xpc_dictionary_set_data(
        reply, agentControlPayloadKey, rawBuffer.baseAddress, rawBuffer.count
      )
    }
    xpc_connection_send_message(peer, reply)
    logger.notice("agent session reply sent bytes=\(data.count, privacy: .public)")
  }

  private func encode(_ response: AgentControlResponse) -> Data? {
    do {
      return try JSONEncoder().encode(response)
    } catch {
      logger.error(
        """
        agent session response encode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=reply-nil
        """
      )
      return nil
    }
  }
}

// MARK: - PeerSubscription

/// One client's place in the push registry, for the life of its connection.
///
/// The registry holds plain send closures so it stays free of the transport, so the
/// connection handle is held here and only the send is published. Keeping the token here
/// means the object that registered the client is the one that drops it when the
/// connection reports it is gone.
private final class PeerSubscription: @unchecked Sendable {
  private let peer: xpc_connection_t
  private let registry: SubscriberRegistry
  private let token = Mutex<UUID?>(nil)

  init(peer: xpc_connection_t, registry: SubscriberRegistry) {
    self.peer = peer
    self.registry = registry
  }

  /// Registers this client once. Asking twice on one connection leaves a single
  /// subscriber, so a repeat cannot double every push it receives.
  func begin() {
    let registered = token.withLock { current -> Bool in
      guard current == nil else {
        return false
      }
      current = registry.add { [weak self] snapshot in
        self?.sendPush(snapshot)
      }
      return true
    }
    guard registered else {
      return
    }
    logger.notice("agent session listener registered subscriber")
  }

  func end() {
    let removed = token.withLock { current -> UUID? in
      let previous = current
      current = nil
      return previous
    }
    guard let removed else {
      return
    }
    registry.remove(removed)
    logger.notice("agent session listener removed subscriber")
  }

  /// A push answers no request, so it travels as a fresh dictionary on the connection.
  /// Building a reply needs an inbound message to reply to, and there is none here.
  private func sendPush(_ payload: Data) {
    let message = xpc_dictionary_create_empty()
    payload.withUnsafeBytes { rawBuffer in
      xpc_dictionary_set_data(
        message, agentControlPayloadKey, rawBuffer.baseAddress, rawBuffer.count
      )
    }
    xpc_connection_send_message(peer, message)
  }
}

//
//  AgentRelayBridge+Receive.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-12.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Datagram bridge

/// The receive and forward half of the relay bridge: it routes each inbound
/// datagram, admits a phone link only from a session prime carrying the current
/// relay-session id, and forwards real traffic between the Mac and the carrying
/// phone link. Every method runs only on `AgentRelayBridge.queue`.
extension AgentRelayBridge {
  func receive(on connection: NWConnection, fromMac: Bool) {
    connection.receiveMessage { [weak self, weak connection] data, _, _, error in
      guard let self, let connection else {
        return
      }
      if fromMac {
        handleMacReceive(connection, data: data, error: error)
      } else {
        handlePhoneReceive(connection, data: data, error: error)
      }
    }
  }

  // The Mac loopback receive: forward real data to the carrying phone link and
  // tear the bridge down on a receive error, since the extension connection is
  // the single downstream side.
  private func handleMacReceive(_ connection: NWConnection, data: Data?, error: NWError?) {
    if let error {
      logger.error(
        """
        agent relay bridge receive failed mac=true \
        error=\(error.localizedDescription, privacy: .public)
        """
      )
      connection.cancel()
      clearIfCurrent(connection, isLoopback: true, reason: "receive-error")
      return
    }
    if let data, !data.isEmpty {
      forward(data, fromMac: true)
    }
    receive(on: connection, fromMac: true)
  }

  // The phone receive boundary: an unadmitted connection is admitted only by a
  // session prime carrying the current relay-session id; an admitted link
  // refreshes its liveness and bridges its datagrams.
  private func handlePhoneReceive(_ connection: NWConnection, data: Data?, error: NWError?) {
    if !didLogPhoneReceive {
      didLogPhoneReceive = true
      logger.notice("agent relay bridge phone receive path active")
    }
    if let error {
      handlePhoneReceiveError(connection, error: error)
      return
    }
    if !isAdoptedPhoneLink(connection) {
      admitPhoneLink(connection, prime: data)
      return
    }
    noteLinkActivity(on: connection)
    bridgePhoneDatagram(connection, data: data)
    receive(on: connection, fromMac: false)
  }

  // An empty datagram surfaces as NWError ENODATA and carries no session prime,
  // so it can never admit a link; it only refreshes and echoes an already
  // admitted one. An unadmitted connection sending only empties is ignored.
  private func handlePhoneReceiveError(_ connection: NWConnection, error: NWError) {
    guard isAdoptedPhoneLink(connection) else {
      return
    }
    if case .posix(let code) = error, code == .ENODATA {
      noteLinkActivity(on: connection)
      sendHeartbeatEcho(on: connection)
    }
    if !didLogPhoneReceiveError {
      didLogPhoneReceiveError = true
      logger.notice(
        "agent relay bridge phone receive error tolerated; re-arming, reaper owns liveness"
      )
    }
    receive(on: connection, fromMac: false)
  }

  // Admits an unadmitted phone connection only when its first datagram is a
  // session prime whose id matches the promoted control session. A missing or
  // non-matching id means the sender is not the peer being served, so the
  // connection is dropped without forming a link, which is what stops a stray
  // second sender from creating or holding a link.
  private func admitPhoneLink(_ connection: NWConnection, prime: Data?) {
    guard let sessionID = prime.flatMap(RelaySessionPrime.sessionID(from:)),
      sessionID == currentSessionID
    else {
      connection.cancel()
      if !didLogForeignSession {
        didLogForeignSession = true
        logger.notice("agent relay bridge rejected relay prime reason=foreign-session")
      }
      return
    }
    addPhoneLink(for: connection, sessionID: sessionID)
    noteLinkActivity(on: connection)
    sendHeartbeatEcho(on: connection)
    receive(on: connection, fromMac: false)
  }

  // Bridges one datagram from an admitted phone link: a heartbeat or a re-prime
  // is echoed so the iPhone confirms the link end to end; anything else is real
  // relay traffic forwarded to the Mac.
  private func bridgePhoneDatagram(_ connection: NWConnection, data: Data?) {
    guard let data, !data.isEmpty else {
      sendHeartbeatEcho(on: connection)
      return
    }
    if RelayHeartbeat.isHeartbeat(data) || RelaySessionPrime.sessionID(from: data) != nil {
      sendHeartbeatEcho(on: connection)
      return
    }
    forward(data, fromMac: false)
  }

  private func forward(_ data: Data, fromMac: Bool) {
    let target = fromMac ? egressConnection : macConnection
    guard let target else {
      return
    }
    target.send(
      content: data,
      completion: .contentProcessed { [weak self, weak target] error in
        guard let error else {
          return
        }
        logger.error(
          """
          agent relay bridge send failed toMac=\(!fromMac, privacy: .public) \
          error=\(error.localizedDescription, privacy: .public)
          """
        )
        // A send failure on the carrying phone link (interface gone, no route to
        // host) is the reliable signal that a UDP path went away, since the
        // connection state may never reach .failed. Drop the link so the carrying
        // choice moves to another open link at once.
        guard fromMac, let self, let target else {
          return
        }
        target.cancel()
        removePhoneLink(for: target, reason: "send-error")
      }
    )
  }

  // Echoes the iPhone's heartbeat back on the same link so that side can tell the
  // link is alive end to end. A heartbeat is never forwarded to the Mac, and the
  // echo carries the heartbeat payload because an empty datagram does not
  // reliably arrive on the iPhone side.
  func sendHeartbeatEcho(on connection: NWConnection) {
    if !didLogHeartbeatEcho {
      didLogHeartbeatEcho = true
      logger.notice("agent relay bridge heartbeat echo path active")
    }
    connection.send(
      content: RelayHeartbeat.payload,
      completion: .contentProcessed { error in
        if let error {
          logger.error(
            "agent relay bridge heartbeat echo failed error=\(error.localizedDescription, privacy: .public)"
          )
        }
      }
    )
  }
}

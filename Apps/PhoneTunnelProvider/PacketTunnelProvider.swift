//
//  PacketTunnelProvider.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import CellTunnelRelay
import Foundation
import NetworkExtension

private let logger = CellTunnelLog.logger(category: .daemon)

// The provider installs a no-route tunnel so neither the phone's own traffic nor
// the relay's cellular socket is captured, then runs the iPhone relay runtime in
// the background. The server endpoint is not in providerConfiguration; it arrives
// at runtime over the Mac control channel.
private let tunnelRemoteAddress = "127.0.0.1"
private let tunnelLocalAddress = "10.7.0.2"
private let tunnelLocalSubnetMask = "255.255.255.255"

// A unique-local IPv6 address for the tunnel interface so iOS reports a VPN IPv6
// address. It is a host address with no included routes, matching the IPv4
// address, so the provider still captures none of the phone's traffic.
private let tunnelLocalAddressIPv6 = "fd00::2"
private let tunnelLocalIPv6PrefixLength: NSNumber = 128

// The completion handler arrives from Objective-C without a Sendable marking;
// box it so the start Task can call it across the concurrency boundary.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

// MARK: - PacketTunnelProvider

/// The iOS host for the relay runtime. It owns a no-route packet tunnel that keeps
/// the app alive in the background, and it forwards the tunnel lifecycle and the
/// app control messages to one `RelayRuntime`, which owns the relay itself. The
/// same `RelayRuntime` runs in-process in the simulator, where this Network
/// Extension host has no launchable `nehelper`.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
  // This Network Extension is the device composition root: it builds the pinned
  // graph, where each connection binds to its physical interface. The device name
  // comes from the app group the host app published it to, since the extension has
  // no UIKit to read `UIDevice.current.name` itself.
  private let runtime = RelayRuntime(
    composition: .pinned(
      deviceName: resolvedRelayServiceDeviceName(
        defaults: UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
      )
    )
  )

  // Held so the stop can complete after teardown finishes; invoked once.
  private var stopCompletion: (() -> Void)?

  override init() {
    super.init()
    logger.notice("PhoneTunnelProvider initialized")
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let optionCount = options?.count ?? 0
    logger.notice(
      "tunnel start request received optionsCount=\(optionCount, privacy: .public)"
    )

    let ipv4Settings = NEIPv4Settings(
      addresses: [tunnelLocalAddress],
      subnetMasks: [tunnelLocalSubnetMask]
    )
    let ipv6Settings = NEIPv6Settings(
      addresses: [tunnelLocalAddressIPv6],
      networkPrefixLengths: [tunnelLocalIPv6PrefixLength]
    )
    // No includedRoutes on either family: the provider must capture neither
    // the phone's traffic nor the relay's own cellular socket, so the relay
    // can egress.
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
    settings.ipv4Settings = ipv4Settings
    settings.ipv6Settings = ipv6Settings

    logger.notice(
      """
      tunnel network settings prepared remote=\(tunnelRemoteAddress, privacy: .public) \
      local=\(tunnelLocalAddress, privacy: .public)
      """
    )
    let handlerBox = UncheckedSendableBox(completionHandler)
    let relayRuntime = self.runtime
    self.setTunnelNetworkSettings(settings) { error in
      if let error {
        logger.error(
          """
          setTunnelNetworkSettings failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=propagate-to-NE
          """
        )
        handlerBox.value(error)
        return
      }
      logger.notice("setTunnelNetworkSettings applied success=true")
      relayRuntime.start()
      handlerBox.value(nil)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    logger.notice(
      "tunnel stop request received reason=\(String(describing: reason), privacy: .public)"
    )
    stopCompletion = completionHandler
    runtime.stop()
    finishStop()
  }

  private func finishStop() {
    stopCompletion?()
    stopCompletion = nil
    logger.notice("tunnel stop completion handler called")
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    let handlerBox = UncheckedSendableBox(completionHandler)
    let request: ProviderControlRequest
    do {
      request = try JSONDecoder().decode(
        ProviderControlEnvelope.self,
        from: messageData
      ).request
    } catch {
      logger.error(
        """
        app message decode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=reply-failure
        """
      )
      handlerBox.value?(encodeResponse(failureMessage: "decode failed"))
      return
    }
    let response = handleProviderRequest(request)
    handlerBox.value?(encodeResponse(response))
  }

  private func handleProviderRequest(
    _ request: ProviderControlRequest
  ) -> ProviderControlResponse {
    switch request {
    case .status:
      return ProviderControlResponse(status: runtime.statusSnapshot())
    case .reloadConfig:
      // WireGuard runs on the Mac; the iPhone relay holds no config to reload.
      return ProviderControlResponse(status: runtime.statusSnapshot())
    case .setRouteState:
      // Route gating is a Mac-side concern; the iPhone relay ignores it.
      return ProviderControlResponse(status: runtime.statusSnapshot())
    case .setRoutingEnabled(let enabled):
      runtime.setRoutingEnabled(enabled)
      return ProviderControlResponse(status: runtime.statusSnapshot())
    case .selectPeer(let id):
      runtime.selectPeer(id: id)
      return ProviderControlResponse(status: runtime.statusSnapshot())
    case .discoverySnapshot:
      return ProviderControlResponse(discovery: TunnelDiscoverySnapshot())
    }
  }

  private func encodeResponse(_ response: ProviderControlResponse) -> Data? {
    do {
      return try JSONEncoder().encode(response)
    } catch {
      logger.error(
        """
        app message response encode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=reply-failure
        """
      )
      return encodeResponse(failureMessage: "encode failed")
    }
  }

  private func encodeResponse(failureMessage: String) -> Data? {
    do {
      return try JSONEncoder().encode(
        ProviderControlResponse(failureMessage: failureMessage)
      )
    } catch {
      logger.error(
        """
        app message failure encode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=reply-nil
        """
      )
      return nil
    }
  }
}

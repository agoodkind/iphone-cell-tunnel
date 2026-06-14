//
//  TunnelRelayEndpoint.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation

private let hostPortComponentCount = 2

public let usbmuxdEndpointPrefix = "usbmuxd:"
public let tunneldEndpointPrefix = "tunneld:"

private let prefixedEndpointSchemes = [usbmuxdEndpointPrefix, tunneldEndpointPrefix]

private func prefixedSchemeForHost(_ host: String) -> String? {
  for scheme in prefixedEndpointSchemes where host.hasPrefix(scheme) {
    return scheme
  }
  return nil
}

// MARK: - TunnelRelayEndpoint

public struct TunnelRelayEndpoint: Codable, Equatable, Hashable, Sendable {
  public var host: String
  public var port: Int
  public var addressFamily: TunnelAddressFamily

  public init(host: String, port: Int, addressFamily: TunnelAddressFamily = .unspecified) {
    self.host = host
    self.port = port
    self.addressFamily = addressFamily
  }

  public var socketAddress: String {
    if prefixedSchemeForHost(host) != nil {
      return "\(host):\(port)"
    }
    if host.contains(":") {
      return "[\(host)]:\(port)"
    }
    return "\(host):\(port)"
  }

  public var isConfigured: Bool {
    !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0
  }

  public static func parse(argument: String) throws -> Self {
    let trimmedArgument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedArgument.isEmpty {
      throw TunnelDaemonError.usage("relay endpoint is empty")
    }

    for scheme in prefixedEndpointSchemes where trimmedArgument.hasPrefix(scheme) {
      let body = String(trimmedArgument.dropFirst(scheme.count))
      guard let lastColonIndex = body.lastIndex(of: ":") else {
        throw TunnelDaemonError.controlFailure(
          TunnelControlFailure(
            errorCode: .invalidRelayEndpoint,
            message: "invalid \(scheme.dropLast()) relay endpoint")
        )
      }
      let udid = String(body[..<lastColonIndex])
      let portString = String(body[body.index(after: lastColonIndex)...])
      guard !udid.isEmpty, let parsedPort = Int(portString), parsedPort > 0 else {
        throw TunnelDaemonError.controlFailure(
          TunnelControlFailure(
            errorCode: .invalidRelayEndpoint,
            message: "invalid \(scheme.dropLast()) relay endpoint")
        )
      }
      return Self(host: "\(scheme)\(udid)", port: parsedPort, addressFamily: .unspecified)
    }

    if trimmedArgument.hasPrefix("[") {
      guard let closingBracketIndex = trimmedArgument.lastIndex(of: "]"),
        let separatorIndex = trimmedArgument[closingBracketIndex...].firstIndex(of: ":")
      else {
        throw TunnelDaemonError.controlFailure(
          TunnelControlFailure(
            errorCode: .invalidRelayEndpoint, message: "invalid relay endpoint")
        )
      }
      let parsedHost = String(
        trimmedArgument[
          trimmedArgument.index(after: trimmedArgument.startIndex)..<closingBracketIndex]
      )
      let portString = String(
        trimmedArgument[trimmedArgument.index(after: separatorIndex)...])
      guard let parsedPort = Int(portString), parsedPort > 0 else {
        throw TunnelDaemonError.controlFailure(
          TunnelControlFailure(
            errorCode: .invalidRelayEndpoint, message: "invalid relay endpoint")
        )
      }
      return Self(host: parsedHost, port: parsedPort, addressFamily: .ipv6)
    }

    let components = trimmedArgument.split(
      separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard components.count == hostPortComponentCount, let parsedPort = Int(components[1]),
      parsedPort > 0
    else {
      throw TunnelDaemonError.controlFailure(
        TunnelControlFailure(
          errorCode: .invalidRelayEndpoint, message: "invalid relay endpoint")
      )
    }

    let parsedHost = String(components[0])
    let parsedFamily: TunnelAddressFamily = parsedHost.contains(":") ? .ipv6 : .ipv4
    return Self(host: parsedHost, port: parsedPort, addressFamily: parsedFamily)
  }
}

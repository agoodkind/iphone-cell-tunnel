//
//  TunnelEnvironmentReport.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - TunnelEnvironmentCheckResult

/// One named environment check and its rendered value, a row in the
/// environment report.
public struct TunnelEnvironmentCheckResult: Codable, Equatable, Sendable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

// MARK: - TunnelEnvironmentReport

/// The full environment report: the ordered check results and their
/// `key=value` rendering for the CLI.
public struct TunnelEnvironmentReport: Codable, Equatable, Sendable {
  public var checks: [TunnelEnvironmentCheckResult]

  public init(checks: [TunnelEnvironmentCheckResult] = []) {
    self.checks = checks
  }

  public var renderedOutput: String {
    checks.map { "\($0.name)=\($0.value)" }.joined(separator: "\n")
  }
}

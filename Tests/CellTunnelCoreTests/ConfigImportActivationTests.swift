//
//  ConfigImportActivationTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - ConfigImportActivationTests

/// Covers the request that adds a configuration.
///
/// Adding one and choosing which one is in force are separate things a person does. When
/// one request could not say so, a client that only wanted to add one had to send a
/// second request undoing the activation, and anything interrupting it between the two
/// left the wrong configuration in force.
struct ConfigImportActivationTests {
  private struct RequestShape: Decodable {
    struct Fields: Decodable {
      let configActivate: Bool
      let kind: String
    }

    let request: Fields
  }

  private func roundTrip(_ request: AgentControlRequest) throws -> AgentControlRequest {
    let encoded = try JSONEncoder().encode(AgentControlEnvelope(request: request))
    return try JSONDecoder().decode(AgentControlEnvelope.self, from: encoded).request
  }

  @Test func addingWithoutActivatingSurvivesTheRoundTrip() throws {
    let decoded = try roundTrip(
      .importConfig(name: "work", text: "[Interface]", activate: false))

    guard case let .importConfig(name, _, activate) = decoded else {
      Issue.record("decoded \(decoded) instead of an import")
      return
    }
    #expect(name == "work")
    #expect(activate == false)
  }

  @Test func addingAndActivatingSurvivesTheRoundTrip() throws {
    let decoded = try roundTrip(
      .importConfig(name: "work", text: "[Interface]", activate: true))

    guard case let .importConfig(_, _, activate) = decoded else {
      Issue.record("decoded \(decoded) instead of an import")
      return
    }
    #expect(activate)
  }

  /// The choice travels as its own field rather than being implied, so a reader can tell
  /// what was asked for.
  @Test func theChoiceTravelsAsItsOwnField() throws {
    let encoded = try JSONEncoder().encode(
      AgentControlEnvelope(
        request: .importConfig(name: "work", text: "[Interface]", activate: false)))

    let shape = try JSONDecoder().decode(RequestShape.self, from: encoded)

    #expect(shape.request.kind == "importConfig")
    #expect(shape.request.configActivate == false)
  }

  /// A client that predates the field sent this only when it did mean to activate, so its
  /// absence has to read as activate. Reading it as the new behaviour would silently stop
  /// activating for every older client.
  @Test func anOlderRequestWithNoChoiceActivates() throws {
    let older = """
      {"version":3,"request":{"kind":"importConfig","configName":"work",\
      "configText":"[Interface]"}}
      """

    let decoded = try JSONDecoder().decode(
      AgentControlEnvelope.self, from: Data(older.utf8)
    ).request

    guard case let .importConfig(_, _, activate) = decoded else {
      Issue.record("decoded \(decoded) instead of an import")
      return
    }
    #expect(activate)
  }

  /// Importing a file is a person choosing a configuration to use, so the command line
  /// activates by default and asks not to only when told.
  @Test func theCommandLineActivatesUnlessToldNotTo() throws {
    let plain = try ConfigsCommand.parse(arguments: ["import", "/tmp/work.conf"])
    let explicit = try ConfigsCommand.parse(
      arguments: ["import", "/tmp/work.conf", "--no-activate"])

    #expect(plain == .importFile(path: "/tmp/work.conf", activate: true))
    #expect(explicit == .importFile(path: "/tmp/work.conf", activate: false))
  }

  /// The flag is not a path, so asking for it without one is still a usage error rather
  /// than an import of a file named after the flag.
  @Test func theFlagAloneIsStillAUsageError() {
    #expect(throws: TunnelDaemonError.self) {
      try ConfigsCommand.parse(arguments: ["import", "--no-activate"])
    }
  }
}

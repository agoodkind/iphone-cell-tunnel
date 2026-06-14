//
//  TunnelConfigStoreTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - TunnelConfigStoreTests

private let fixedConfigID = UUID()

struct TunnelConfigStoreTests {
  @Test func addStoresConfigAndLeavesActiveNil() throws {
    let date = Date(timeIntervalSince1970: 1_717_200_000)
    let store: TunnelConfigStore = InMemoryTunnelConfigStore(
      now: { date }, makeID: { fixedConfigID })

    let config = try store.add(name: "Primary", text: "PrivateKey = example")

    #expect(
      config
        == StoredTunnelConfig(
          id: fixedConfigID,
          name: "Primary",
          text: "PrivateKey = example",
          createdAt: date
        ))
    #expect(store.list() == [config])
    #expect(store.activeID == nil)
  }

  @Test func setActiveMarksOneConfigThenSwitchesToAnother() throws {
    let store: TunnelConfigStore = InMemoryTunnelConfigStore()
    let firstConfig = try store.add(name: "First", text: "first")
    let secondConfig = try store.add(name: "Second", text: "second")

    store.setActive(id: firstConfig.id)

    #expect(store.activeID == firstConfig.id)

    store.setActive(id: secondConfig.id)

    #expect(store.activeID == secondConfig.id)
  }

  @Test func updateReplacesText() throws {
    let store: TunnelConfigStore = InMemoryTunnelConfigStore()
    let config = try store.add(name: "Primary", text: "old text")

    try store.update(id: config.id, text: "new text")

    #expect(store.list().first?.text == "new text")
  }

  @Test func deletingActiveConfigClearsActiveID() throws {
    let store: TunnelConfigStore = InMemoryTunnelConfigStore()
    let config = try store.add(name: "Primary", text: "text")
    store.setActive(id: config.id)

    try store.delete(id: config.id)

    #expect(store.list().isEmpty)
    #expect(store.activeID == nil)
  }

  @Test func addDeduplicatedReusesEntryWithMatchingText() throws {
    let store: TunnelConfigStore = InMemoryTunnelConfigStore()
    let first = try store.addDeduplicated(name: "Home", text: "same text")

    let second = try store.addDeduplicated(name: "Home again", text: "same text")

    #expect(second.id == first.id)
    #expect(store.list().count == 1)
  }

  @Test func addDeduplicatedAddsWhenTextDiffers() throws {
    let store: TunnelConfigStore = InMemoryTunnelConfigStore()
    _ = try store.addDeduplicated(name: "Home", text: "first text")

    _ = try store.addDeduplicated(name: "Work", text: "second text")

    #expect(store.list().count == 2)
  }

  @Test func addDeduplicatedIgnoresWhitespaceAndLineEndingDifferences() throws {
    let store: TunnelConfigStore = InMemoryTunnelConfigStore()
    let first = try store.addDeduplicated(
      name: "Home", text: "[Interface]\nAddress = 10.0.0.2/32\n")

    let second = try store.addDeduplicated(
      name: "Home again", text: "[Interface]\r\nAddress = 10.0.0.2/32")

    #expect(second.id == first.id)
    #expect(store.list().count == 1)
  }

  @Test func summariesDropConfigText() throws {
    let store: TunnelConfigStore = InMemoryTunnelConfigStore()
    let saved = try store.add(name: "Home", text: "PrivateKey = secret")

    let summaries = store.summaries()

    #expect(
      summaries == [
        TunnelConfigSummary(id: saved.id, name: "Home", createdAt: saved.createdAt)
      ])
  }

  @Test func renameChangesNameOnly() throws {
    let date = Date(timeIntervalSince1970: 1_717_200_000)
    let store: TunnelConfigStore = InMemoryTunnelConfigStore(
      now: { date }, makeID: { fixedConfigID })
    let config = try store.add(name: "Old Name", text: "text")

    try store.rename(id: config.id, name: "New Name")

    #expect(
      store.list() == [
        StoredTunnelConfig(
          id: config.id,
          name: "New Name",
          text: config.text,
          createdAt: config.createdAt
        )
      ])
  }
}

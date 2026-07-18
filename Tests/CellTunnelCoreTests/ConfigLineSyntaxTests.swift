//
//  ConfigLineSyntaxTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-17.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

private let fixtureSecretValue = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

// MARK: - ConfigLineSyntaxTests

struct ConfigLineSyntaxTests {
  @Test func sectionHeaderLineIsClassifiedAsSectionHeader() {
    let lines = ConfigLineSyntax.classify("[Interface]")

    #expect(lines.count == 1)
    #expect(lines[0].kind == .sectionHeader)
    #expect(lines[0].text == "[Interface]")
  }

  @Test func commentLineIsClassifiedAsComment() {
    let lines = ConfigLineSyntax.classify("# a note")

    #expect(lines[0].kind == .comment)
  }

  @Test func plainKeyValueLineIsClassifiedAsPlain() {
    let lines = ConfigLineSyntax.classify("Address = 10.0.0.2/32")

    #expect(lines[0].kind == .plain)
  }

  @Test func privateKeyLineSplitsLabelFromValue() {
    let line = "PrivateKey = \(fixtureSecretValue)"  // gitleaks:allow
    let lines = ConfigLineSyntax.classify(line)

    #expect(lines[0].kind == .secret(label: "PrivateKey =", value: fixtureSecretValue))
  }

  @Test func presharedKeyLineIsClassifiedAsSecret() {
    let line = "PresharedKey = \(fixtureSecretValue)"  // gitleaks:allow
    let lines = ConfigLineSyntax.classify(line)

    #expect(lines[0].kind == .secret(label: "PresharedKey =", value: fixtureSecretValue))
  }

  @Test func publicKeyLineIsNotTreatedAsSecret() {
    let lines = ConfigLineSyntax.classify("PublicKey = \(fixtureSecretValue)")

    #expect(lines[0].kind == .plain)
  }

  @Test func indentedPrivateKeyLineKeepsIndentInLabel() {
    let line = "  PrivateKey = \(fixtureSecretValue)"  // gitleaks:allow
    let lines = ConfigLineSyntax.classify(line)

    #expect(lines[0].kind == .secret(label: "  PrivateKey =", value: fixtureSecretValue))
  }

  @Test func blankLinesArePreservedAndIndexedByPosition() {
    let config = """
      [Interface]

      Address = 10.0.0.2/32
      """
    let lines = ConfigLineSyntax.classify(config)

    #expect(lines.count == 3)
    #expect(lines[0].id == 0)
    #expect(lines[1].id == 1)
    #expect(lines[1].text.isEmpty)
    #expect(lines[1].kind == .plain)
    #expect(lines[2].id == 2)
  }

  @Test func multiLineConfigClassifiesEachLineByKind() {
    let privateKeyLine = "PrivateKey = \(fixtureSecretValue)"  // gitleaks:allow
    let config = [
      "[Interface]",
      privateKeyLine,
      "# note",
      "Address = 10.0.0.2/32",
    ].joined(separator: "\n")
    let kinds = ConfigLineSyntax.classify(config).map(\.kind)

    #expect(
      kinds == [
        .sectionHeader,
        .secret(label: "PrivateKey =", value: fixtureSecretValue),
        .comment,
        .plain,
      ]
    )
  }
}

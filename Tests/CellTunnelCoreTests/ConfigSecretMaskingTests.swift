//
//  ConfigSecretMaskingTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - ConfigSecretMaskingTests

struct ConfigSecretMaskingTests {
  @Test func privateKeyLineIsMaskedAndAddressLineIsUnchanged() {
    let privateKeyValue = String(repeating: "A", count: 43) + "="
    let addressLine = "Address = 10.0.0.2/32"
    let config = """
      [Interface]
      PrivateKey = \(privateKeyValue)
      \(addressLine)
      """

    let maskedConfig = ConfigSecretMasking.maskingPrivateKey(in: config)

    #expect(maskedConfig.contains("PrivateKey = .............."))
    #expect(maskedConfig.contains(addressLine))
    #expect(!maskedConfig.contains(privateKeyValue))
  }

  @Test func configWithoutPrivateKeyLineIsUnchanged() {
    let addressLine = "Address = 10.0.0.2/32"
    let config = """
      [Interface]
      \(addressLine)

      [Peer]
      PublicKey = example-public-key
      """

    let maskedConfig = ConfigSecretMasking.maskingPrivateKey(in: config)

    #expect(maskedConfig == config)
  }
}

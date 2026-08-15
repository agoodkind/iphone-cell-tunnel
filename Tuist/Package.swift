// swift-tools-version: 6.0
//
//  Package.swift
//  CellTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import PackageDescription

#if TUIST
  import Foundation
  import ProjectDescription

  // Resolve the vendored libwg-go.a search path from this manifest's location so
  // each checkout (the main repo or any worktree) links the bridge from its own
  // .build/vendor, the same directory CellTunnelDev builds the bridge into. A
  // hardcoded absolute path makes worktrees link the main repo's copy instead.
  let wireGuardVendorSearchPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("vendor", isDirectory: true)
    .path

  // This product ships Apple silicon only, and the vendored WireGuard bridge is
  // built for that architecture alone, so an Intel slice has nothing to link
  // against and fails at the linker rather than at configuration time.
  let appleSiliconOnly: SettingsDictionary = ["ARCHS": "arm64"]

  // These frameworks are embedded in the downloadable app, so notarization checks
  // them too and refuses a signature with no secure timestamp. Xcode passes
  // `--timestamp=none` during a plain build unless this overrides it. The setting
  // stays off outside the Developer ID build, where a timestamp would mean
  // contacting Apple's timestamp server on every local signing. The project
  // manifest applies the same flag to the targets it owns.
  let notarizableSigning: SettingsDictionary =
    if Environment.developerIdSigning.getBoolean(default: false) {
      ["OTHER_CODE_SIGN_FLAGS": "$(inherited) --timestamp"]
    } else {
      [:]
    }

  let packageSettings = PackageSettings(
    productTypes: [
      "WireGuardKit": .framework
    ],
    baseSettings: .settings(
      base: appleSiliconOnly.merging(notarizableSigning) { _, new in new }),
    targetSettings: [
      "WireGuardKit": [
        "LIBRARY_SEARCH_PATHS": [wireGuardVendorSearchPath],
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
      ],
      "WireGuardKitGo": [
        "LIBRARY_SEARCH_PATHS": [wireGuardVendorSearchPath],
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
      ],
      "WireGuardKitC": [
        "MACOSX_DEPLOYMENT_TARGET": "26.0"
      ],
    ]
  )
#endif

let package = Package(
  name: "CellTunnelTuistDependencies",
  dependencies: [
    .package(url: "https://github.com/agoodkind/wireguard-apple.git", branch: "master")
  ]
)

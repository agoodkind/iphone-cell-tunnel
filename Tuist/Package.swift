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

  let packageSettings = PackageSettings(
    productTypes: [
      "WireGuardKit": .framework
    ],
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

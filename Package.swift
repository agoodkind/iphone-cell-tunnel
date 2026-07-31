// swift-tools-version: 6.0
//
//  Package.swift
//  CellTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import PackageDescription

let package = Package(
  name: "CellTunnel",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "CellTunnelCore", targets: ["CellTunnelCore"]),
    .library(name: "CellTunnelLog", targets: ["CellTunnelLog"]),
    .executable(name: "celltunnelctl", targets: ["celltunnelctl"]),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "CellTunnelCore",
      dependencies: ["CellTunnelLog"]
    ),
    .target(name: "CellTunnelLog"),
    .target(
      name: "CellTunnelCatalystPresentation",
      dependencies: ["CellTunnelCore"],
      path: "Apps/iOS/Presentation",
      sources: ["ConfigLibraryPresentation.swift"],
      swiftSettings: [.define("CATALYST_PRESENTATION_TESTING")]
    ),
    .target(
      name: "CellTunnelSignalSupport",
      path: "Sources/CellTunnelSignalSupport",
      publicHeadersPath: "include"
    ),
    // The tunnel extension's runtime is otherwise reachable only through the
    // Tuist app target, which no test target depends on. These three files hold
    // the route gate, the relay socket, and the liveness rule that withdraws
    // routes, so they are mapped here to be driven from the package tests.
    .target(
      name: "CellTunnelTunnelRuntime",
      dependencies: [
        "CellTunnelCore",
        "CellTunnelLog",
      ],
      path: "Apps/macOS/TunnelProvider/Runtime",
      sources: [
        "RelayLivenessMonitor.swift",
        "RelayTransport.swift",
        "RouteGate.swift",
      ]
    ),
    .executableTarget(
      name: "celltunnelctl",
      dependencies: [
        "CellTunnelCore",
        "CellTunnelLog",
        "CellTunnelSignalSupport",
      ],
      path: "Tools/CellTunnelCtl"
    ),
    .testTarget(
      name: "CellTunnelCoreTests",
      dependencies: [
        "CellTunnelCatalystPresentation",
        "CellTunnelCore",
        "CellTunnelLog",
        "CellTunnelTunnelRuntime",
      ]
    ),
  ]
)

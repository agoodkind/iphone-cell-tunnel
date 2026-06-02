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
        .executableTarget(
            name: "celltunnelctl",
            dependencies: [
                "CellTunnelCore",
                "CellTunnelLog",
            ],
            path: "Tools/CellTunnelCtl"
        ),
        .testTarget(
            name: "CellTunnelCoreTests",
            dependencies: [
                "CellTunnelCore",
                "CellTunnelLog",
            ]
        ),
    ]
)

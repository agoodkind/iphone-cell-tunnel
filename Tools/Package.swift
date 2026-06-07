// swift-tools-version: 6.0
//
//  Package.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import PackageDescription

// swift-makefile is consumed upstream by default. SWIFT_MK_DEV_DIR overrides it to a
// local checkout for development, the same override the make layer uses; never hardcode
// a relative path to it.
let swiftMakefileDependency: Package.Dependency = {
    let devDir = ProcessInfo.processInfo.environment["SWIFT_MK_DEV_DIR"] ?? ""
    if !devDir.trimmingCharacters(in: .whitespaces).isEmpty {
        return .package(path: devDir)
    }
    return .package(url: "https://github.com/agoodkind/swift-makefile.git", branch: "main")
}()

let package = Package(
    name: "CellTunnelTools",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "CellTunnelDev", targets: ["CellTunnelDev"]),
        .executable(name: "LoggingAudit", targets: ["LoggingAudit"]),
    ],
    dependencies: [
        // swift-mk creates this symlink to the repo root with the correct basename, so
        // the self-reference resolves from any worktree. The fragile_package_path rule
        // forbids a bare `..` here.
        .package(path: "../.make/dev/iphone-cell-tunnel"),
        swiftMakefileDependency,
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CellTunnelDev",
            dependencies: [
                .product(name: "CellTunnelCore", package: "iphone-cell-tunnel"),
                .product(name: "CellTunnelLog", package: "iphone-cell-tunnel"),
                .product(name: "SwiftMkCore", package: "swift-makefile"),
            ],
            path: "CellTunnelDev"
        ),
        .executableTarget(
            name: "LoggingAudit",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            path: "LoggingAudit"
        ),
    ]
)

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

let repositoryRootPath = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .standardizedFileURL
  .path
let swiftMakefileManagedRootPath = URL(fileURLWithPath: repositoryRootPath)
  .appendingPathComponent(".make/dev/iphone-cell-tunnel")
  .standardizedFileURL
  .path
let cellTunnelDependency: Package.Dependency = {
  if FileManager.default.fileExists(atPath: swiftMakefileManagedRootPath) {
    return .package(path: swiftMakefileManagedRootPath)
  }
  return .package(path: repositoryRootPath)
}()
let cellTunnelPackageIdentity: String = {
  if FileManager.default.fileExists(atPath: swiftMakefileManagedRootPath) {
    return "iphone-cell-tunnel"
  }
  return URL(fileURLWithPath: repositoryRootPath).lastPathComponent
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
    // the self-reference resolves from any worktree. Dependabot reads the manifest
    // before bootstrap creates it, so it falls back to the checkout root above.
    cellTunnelDependency,
    swiftMakefileDependency,
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
    .package(url: "https://github.com/rarestype/swift-ip.git", from: "0.3.10"),
  ],
  targets: [
    .executableTarget(
      name: "CellTunnelDev",
      dependencies: [
        .product(name: "CellTunnelCore", package: cellTunnelPackageIdentity),
        .product(name: "CellTunnelLog", package: cellTunnelPackageIdentity),
        .product(name: "IP", package: "swift-ip"),
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

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
let cellTunnelRootPath: String = {
  var isDirectory = ObjCBool(false)
  let pathExists = FileManager.default.fileExists(
    atPath: swiftMakefileManagedRootPath,
    isDirectory: &isDirectory
  )
  if pathExists, isDirectory.boolValue {
    return swiftMakefileManagedRootPath
  }
  return repositoryRootPath
}()
let cellTunnelDependency = Package.Dependency.package(path: cellTunnelRootPath)
let cellTunnelPackageIdentity = URL(fileURLWithPath: cellTunnelRootPath).lastPathComponent

let package = Package(
  name: "CellTunnelTools",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "CellTunnelDev", targets: ["CellTunnelDev"])
  ],
  dependencies: [
    // swift-mk creates this symlink to the repo root with the correct basename, so
    // the self-reference resolves from any worktree. Dependabot reads the manifest
    // before bootstrap creates it, so it falls back to the checkout root above.
    cellTunnelDependency,
    swiftMakefileDependency,
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
    )
  ]
)

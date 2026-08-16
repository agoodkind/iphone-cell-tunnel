//
//  PackageActions.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-15.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import SwiftMkCore

private let packageLogger = CellTunnelLog.logger(category: .build)

// MARK: - Names

/// The one file a person downloads. The name carries no version, because a GitHub
/// release is already the version, and the release smoke names the asset it fetches as
/// a fixed string in the workflow.
let releaseDiskImageName = "CellTunnel.dmg"
private let releaseDiskImageVolumeName = "CellTunnel"
private let releaseDistributionDirectoryName = "dist"
private let releaseStagingDirectoryName = "build/dmg"
private let catalystProductsSuffix = "-maccatalyst"
private let phoneAppBundleFileName = "CellTunnelPhone.app"

/// Where the signing channel reads a locally configured identity from, matching every
/// other signing path in this tool.
private let localSigningConfigurationPaths = ["Config/local.xcconfig"]

// MARK: - Package

/// Build the disk image a person downloads, carrying every product they need.
///
/// The Mac agent hosts the tunnel, the Catalyst app is what they open, and the
/// command-line tool is how they inspect a running relay and read which build they
/// have. Shipping the three in one signed, notarized image means one download installs
/// a working set rather than three archives a person has to match up.
func packageRelease(configuration: String) throws {
  let staging = repoRoot.appendingPathComponent(releaseStagingDirectoryName, isDirectory: true)
  let distribution = repoRoot.appendingPathComponent(
    releaseDistributionDirectoryName, isDirectory: true)
  let diskImage = distribution.appendingPathComponent(releaseDiskImageName)

  try prepareControlTool()
  try stageProducts(configuration: configuration, into: staging)
  try fileManager.createDirectory(at: distribution, withIntermediateDirectories: true)
  if fileManager.fileExists(atPath: diskImage.path) {
    try fileManager.removeItem(at: diskImage)
  }
  try run(
    "hdiutil",
    [
      "create",
      "-volname", releaseDiskImageVolumeName,
      "-srcfolder", staging.path,
      "-format", "UDZO",
      "-quiet",
      diskImage.path,
    ],
    failureMessage: "building the release disk image"
  )
  // Sign the image itself as well as what it carries. The notary service accepts a
  // submission only from a signed image, and the stapled ticket the smoke validates
  // attaches to that signature.
  try sign(paths: [diskImage.path], mode: .dmg, describing: releaseDiskImageName)
  packageLogger.notice(
    "release disk image built path=\(diskImage.path, privacy: .public)")
  printToolOutput("packaged \(diskImage.path)")
}

// MARK: - Control tool

/// Make sure the command-line tool exists and is signed the way a notarized image
/// needs.
///
/// The tool is a SwiftPM product rather than an Xcode target, so no build settings
/// sign it; without an explicit signature the notary service rejects the image, and
/// the release smoke refuses to run an unsigned candidate.
private func prepareControlTool() throws {
  try buildSwiftProduct(guestControlToolName)
  try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
  try installSwiftExecutable(productName: guestControlToolName, outputName: guestControlToolName)
  let tool = productsDirectory.appendingPathComponent(guestControlToolName)
  try sign(paths: [tool.path], mode: .binary, describing: guestControlToolName)
}

// MARK: - Signing

/// Sign through the engine's one signing channel, which resolves the identity from the
/// same inputs the build-time override uses, applies the canonical flags for the kind
/// of artifact, and verifies the result.
private func sign(paths: [String], mode: Codesign.Mode, describing subject: String) throws {
  guard
    Codesign.run(
      paths: paths,
      mode: mode,
      identifier: nil,
      localXcconfigPaths: localSigningConfigurationPaths)
  else {
    throw ToolError.failure(
      """
      signing \(subject) failed; a notarized disk image needs every executable it \
      carries signed, so packaging stops rather than producing an image the notary \
      service will reject
      """
    )
  }
  packageLogger.notice("packaged artifact signed subject=\(subject, privacy: .public)")
}

// MARK: - Staging

/// Copy every product into a clean staging directory, preserving signatures.
///
/// `ditto` is used rather than a file copy because a signed bundle copied as a plain
/// directory tree arrives without its extended attributes, and the signature goes with
/// them.
private func stageProducts(configuration: String, into staging: URL) throws {
  if fileManager.fileExists(atPath: staging.path) {
    try fileManager.removeItem(at: staging)
  }
  try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
  for product in releaseProducts(configuration: configuration) {
    guard fileManager.fileExists(atPath: product.path) else {
      throw ToolError.failure(
        "release product not found: \(product.path); build it before packaging")
    }
    let destination = staging.appendingPathComponent(product.lastPathComponent)
    try run(
      "ditto",
      [product.path, destination.path],
      failureMessage: "staging \(product.lastPathComponent)"
    )
    packageLogger.notice(
      "release product staged name=\(product.lastPathComponent, privacy: .public)")
  }
}

/// The products the disk image carries, in the order a person meets them: the agent
/// that hosts the tunnel, the app they open, then the tool they inspect it with.
private func releaseProducts(configuration: String) -> [URL] {
  let macDirectory = productsDirectory.appendingPathComponent(configuration, isDirectory: true)
  let catalystDirectory = productsDirectory.appendingPathComponent(
    configuration + catalystProductsSuffix, isDirectory: true)
  return [
    macDirectory.appendingPathComponent(agentAppBundleName),
    catalystDirectory.appendingPathComponent(phoneAppBundleFileName),
    productsDirectory.appendingPathComponent(guestControlToolName),
  ]
}

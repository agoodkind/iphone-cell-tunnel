//
//  GuestInstallLayout.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

// MARK: - Constants

private let guestInstallLogger = CellTunnelLog.logger(category: .build)
private let guestInstallDirectoryName = "ict"
private let guestScratchDirectoryName = "cell-tunnel-guest"
private let guestAgentExecutableSubpath = "Contents/MacOS"
private let guestPhoneAppBundleName = "CellTunnelPhone.app"
private let guestCatalystSuffix = "-maccatalyst"
private let guestSimulatorSuffix = "-iphonesimulator"

// MARK: - GuestInstallLayout

/// Where every transferred product lives on the guest. Later steps address the guest
/// only through these paths, so nothing has to rebuild them from a platform suffix.
struct GuestInstallLayout {
  let root: String
  let agentAppPath: String
  let agentBinaryPath: String
  let catalystAppPath: String
  let simulatorAppPath: String
  let controlToolPath: String
  let providerExecutablePath: String
}

// MARK: - Transfer

/// Archive every product, copy it to the guest over the network, prove it arrived
/// byte for byte, and expand it there.
///
/// Two failures shape this. A signed bundle copied as a directory tree arrives ad hoc,
/// because the copy drops the signature, so each bundle travels as a `ditto` archive.
/// Reading a large file back from the tart shared folder fails partway and yields a
/// different checksum, which then presents as a corrupt archive or a broken signature
/// rather than as a copy failure, so the archives go over the network and the guest
/// recomputes each checksum before anything is expanded.
func transferGuestProducts(
  products: [GuestProduct],
  shell: GuestShell,
  configuration: String
) throws -> GuestInstallLayout {
  let root = "/Users/\(shell.user)/\(guestInstallDirectoryName)"
  let scratch = fileManager.temporaryDirectory
    .appendingPathComponent(guestScratchDirectoryName)
  try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
  try shell.runRemote("mkdir -p '\(root)'", describing: "creating the guest install root")

  for product in products {
    if product.isBundle {
      try transferGuestBundle(product: product, shell: shell, scratch: scratch, root: root)
    } else {
      try transferGuestFile(product: product, shell: shell, root: root)
    }
  }

  let agentAppPath = "\(root)/\(configuration)/\(agentAppBundleName)"
  return GuestInstallLayout(
    root: root,
    agentAppPath: agentAppPath,
    agentBinaryPath: "\(agentAppPath)/\(guestAgentExecutableSubpath)/\(agentBinaryName)",
    catalystAppPath: "\(root)/\(configuration)\(guestCatalystSuffix)/\(guestPhoneAppBundleName)",
    simulatorAppPath: "\(root)/\(configuration)\(guestSimulatorSuffix)/\(guestPhoneAppBundleName)",
    controlToolPath: "\(root)/\(guestControlToolName)",
    providerExecutablePath: guestProviderExecutablePath(agentAppPath: agentAppPath)
  )
}

private func transferGuestBundle(
  product: GuestProduct,
  shell: GuestShell,
  scratch: URL,
  root: String
) throws {
  let archive = scratch.appendingPathComponent("\(product.label).zip")
  if fileManager.fileExists(atPath: archive.path) {
    try fileManager.removeItem(at: archive)
  }
  printToolOutput("guest: archiving \(product.label)")
  try run(
    "ditto",
    ["-c", "-k", "--keepParent", product.hostPath.path, archive.path],
    failureMessage: "archiving the \(product.label) product with ditto"
  )
  let hostDigest = try guestFileDigest(at: archive)
  try shell.copyIn([archive], to: guestRemoteScratchDirectory)

  let remoteArchive = "\(guestRemoteScratchDirectory)/\(archive.lastPathComponent)"
  try verifyGuestDigest(
    shell: shell,
    remotePath: remoteArchive,
    expected: hostDigest,
    label: "the \(product.label) archive"
  )

  let bundleName = product.hostPath.lastPathComponent
  let remoteDirectory = "\(root)/\(product.remoteDirectoryName)"
  // The guest cannot build this project and has no dev tool of its own, so unpacking
  // and verifying happen in a script sent to it rather than in typed code here.
  let script = """
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf '\(remoteDirectory)/\(bundleName)'
    mkdir -p '\(remoteDirectory)'
    ditto -x -k '\(remoteArchive)' '\(remoteDirectory)'
    rm -f '\(remoteArchive)'
    codesign -v --verbose=2 '\(remoteDirectory)/\(bundleName)'
    """
  try shell.runScript(
    script,
    named: "install-\(product.label)",
    describing: "unpacking and verifying \(product.label) on the guest"
  )
  guestInstallLogger.notice(
    """
    guest product installed label=\(product.label, privacy: .public) \
    path=\(remoteDirectory, privacy: .public)
    """
  )
  printToolOutput("guest: installed \(product.label) at \(remoteDirectory)/\(bundleName)")
}

private func transferGuestFile(product: GuestProduct, shell: GuestShell, root: String) throws {
  let remotePath = "\(root)/\(product.hostPath.lastPathComponent)"
  let hostDigest = try guestFileDigest(at: product.hostPath)
  try shell.copyIn([product.hostPath], to: remotePath)
  try verifyGuestDigest(
    shell: shell,
    remotePath: remotePath,
    expected: hostDigest,
    label: "the \(product.label) binary"
  )
  try shell.runRemote(
    "chmod +x '\(remotePath)'",
    describing: "making \(product.label) executable on the guest"
  )
  printToolOutput("guest: installed \(product.label) at \(remotePath)")
}

private func verifyGuestDigest(
  shell: GuestShell,
  remotePath: String,
  expected: String,
  label: String
) throws {
  let output = try shell.runRemote(
    "shasum -a 256 '\(remotePath)'",
    describing: "reading the checksum of \(label) on the guest"
  )
  let actual = guestFirstToken(output)
  guard actual == expected else {
    throw ToolError.failure(
      """
      guest: \(label) changed in transit; the host computed \(expected) and the guest \
      computed \(actual) for \(remotePath), so the copy is not the build that was \
      verified and nothing further would describe this build
      """
    )
  }
}

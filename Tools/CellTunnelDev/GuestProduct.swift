//
//  GuestProduct.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import SwiftMkCore

// MARK: - Constants

private let guestProductLogger = CellTunnelLog.logger(category: .build)
private let guestSigningIdentityDefault = "Apple Development"
private let guestSigningStyleDefault = "Automatic"
private let guestSigningTeamKey = "SWIFT_MK_SIGN_TEAM"
private let guestSigningIdentityKey = "SWIFT_MK_SIGN_IDENTITY"
private let guestSigningStyleKey = "SWIFT_MK_SIGN_STYLE"
private let guestRequireSigningKey = "SWIFT_MK_REQUIRE_SIGNING"
private let phoneAppBundleName = "CellTunnelPhone.app"
private let providerBundleName = "CellTunnelTunnelProvider.appex"
private let providerBinaryName = "CellTunnelTunnelProvider"
private let bundleExecutableSubpath = "Contents/MacOS"
private let bundlePlugInsSubpath = "Contents/PlugIns"

let guestControlToolName = "celltunnelctl"

// MARK: - GuestProduct

/// One build product that has to reach the guest, with the directory the build wrote
/// it to and whether its signature must carry the development team.
struct GuestProduct {
  let label: String
  let hostPath: URL
  let isBundle: Bool
  let requiresTeamIdentifier: Bool

  /// The directory name the product is installed under on the guest, taken from the
  /// directory the build wrote it to. Only the macOS slice lands in `Products/<Config>`;
  /// the Catalyst and simulator slices carry the platform suffix xcodebuild appends, so
  /// reading the name back keeps the guest layout identical to the host layout.
  var remoteDirectoryName: String {
    hostPath.deletingLastPathComponent().lastPathComponent
  }
}

// MARK: - Signing environment

/// Turn signing on for this run before anything compiles, and report the team the
/// build will use. The engine writes its signing override only when an identity and a
/// team both resolve, and with neither it writes nothing at all, so the build produces
/// a bundle with no team identifier that launches normally and only fails later in the
/// guest at the keychain with status -34018.
func applyGuestSigningEnvironment() throws -> String {
  let environment = ProcessInfo.processInfo.environment
  let configuredTeam = environment[guestSigningTeamKey]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let team: String
  if let configuredTeam, !configuredTeam.isEmpty {
    team = configuredTeam
  } else {
    team = try developmentTeamFromEnvironment()
  }
  let identity = guestEnvironmentValue(guestSigningIdentityKey) ?? guestSigningIdentityDefault
  let style = guestEnvironmentValue(guestSigningStyleKey) ?? guestSigningStyleDefault
  setenv(guestSigningTeamKey, team, 1)
  setenv(guestSigningIdentityKey, identity, 1)
  setenv(guestSigningStyleKey, style, 1)
  // Requiring signing does not turn signing on; it stops the build before compiling
  // when no team resolves, which turns a silently unusable bundle into an early failure.
  setenv(guestRequireSigningKey, "1", 1)
  guestProductLogger.notice("guest signing configured team=\(team, privacy: .public)")
  return team
}

private func guestEnvironmentValue(_ key: String) -> String? {
  let value = ProcessInfo.processInfo.environment[key]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let value, !value.isEmpty else {
    return nil
  }
  return value
}

// MARK: - Building

/// Build every target the guest runs. The three compile one after another inside a
/// single call, because two builds in the same worktree collide on a locked build
/// database, and each build leaves the other targets' products in place.
func buildGuestProducts(configuration: String) throws {
  try buildProjects(
    targets: [.mac, .macCatalyst, .iphoneSimulator],
    configuration: configuration
  )
}

/// Every product the guest needs, in transfer order.
func guestProducts(configuration: String) -> [GuestProduct] {
  let macDirectory = xcodeConfigurationBuildDirectory(
    configuration: configuration, platformName: macOSPlatformName)
  let catalystDirectory = xcodeConfigurationBuildDirectory(
    configuration: configuration, platformName: macCatalystPlatformName)
  let simulatorDirectory = xcodeConfigurationBuildDirectory(
    configuration: configuration, platformName: iOSSimulatorPlatformName)
  return [
    GuestProduct(
      label: "agent",
      hostPath: macDirectory.appendingPathComponent(agentAppBundleName),
      isBundle: true,
      requiresTeamIdentifier: true
    ),
    GuestProduct(
      label: "catalyst-app",
      hostPath: catalystDirectory.appendingPathComponent(phoneAppBundleName),
      isBundle: true,
      requiresTeamIdentifier: true
    ),
    // A simulator slice is signed ad hoc by design and never carries a team, so it is
    // checked for a valid signature only.
    GuestProduct(
      label: "simulator-app",
      hostPath: simulatorDirectory.appendingPathComponent(phoneAppBundleName),
      isBundle: true,
      requiresTeamIdentifier: false
    ),
    // celltunnelctl is a separate product in Products/, not part of the agent bundle.
    // Leaving it behind makes every later guest command fail on a missing file that
    // reads like a broken agent.
    GuestProduct(
      label: "control-tool",
      hostPath: productsDirectory.appendingPathComponent(guestControlToolName),
      isBundle: false,
      requiresTeamIdentifier: false
    ),
  ]
}

// MARK: - Signature verification

/// Confirm each product is signed the way the guest needs before anything is
/// transferred. An unsigned bundle builds and launches normally, so this is the only
/// point where the difference is visible.
func verifyGuestProductSignatures(_ products: [GuestProduct], expectedTeam: String) throws {
  for product in products {
    guard fileManager.fileExists(atPath: product.hostPath.path) else {
      throw ToolError.failure(
        """
        guest: the \(product.label) product is missing at \(product.hostPath.path); \
        the build did not write it, so rebuild before transferring
        """
      )
    }
    // Simulator products are ad-hoc by design and never reach a keychain, so only the
    // products that must carry a team are checked, matching how the engine verifies a
    // build's products.
    guard product.requiresTeamIdentifier else {
      continue
    }
    // Read the signature through the engine's verification channel rather than
    // spawning codesign here. It compares the reported team against the same
    // signing inputs this run builds with, and logs the found and expected values
    // when they disagree.
    guard SigningVerification.verifyArtifacts(paths: [product.hostPath.path]) else {
      throw ToolError.failure(
        """
        guest: the \(product.label) product at \(product.hostPath.path) is not signed \
        for team \(expectedTeam); such a bundle launches normally and only fails later \
        in the guest at the keychain with status -34018, so rebuild with \
        \(guestSigningIdentityKey) and \(guestSigningTeamKey) set
        """
      )
    }
    printToolOutput("guest: \(product.label) signed for team \(expectedTeam)")
  }
}

// MARK: - Tunnel provider

/// The packet tunnel extension binary this build produced. The system loads the
/// provider from the saved profile's provider bundle identifier, which resolves to the
/// copy embedded in the agent bundle, so the embedded copy is the one a live run has
/// to be running.
func guestProviderExecutable(configuration: String) throws -> URL {
  let embedded = xcodeConfigurationBuildDirectory(
    configuration: configuration, platformName: macOSPlatformName
  )
  .appendingPathComponent(agentAppBundleName)
  .appendingPathComponent(bundlePlugInsSubpath)
  .appendingPathComponent(providerBundleName)
  .appendingPathComponent(bundleExecutableSubpath)
  .appendingPathComponent(providerBinaryName)
  guard fileManager.fileExists(atPath: embedded.path) else {
    throw ToolError.failure(
      """
      guest: the agent bundle carries no tunnel provider at \(embedded.path); without \
      it there is nothing to compare the guest's loaded provider against, so the run \
      cannot report a packet-level result
      """
    )
  }
  return embedded
}

/// The path the guest's copy of the tunnel provider binary lives at, given where the
/// agent bundle was installed.
func guestProviderExecutablePath(agentAppPath: String) -> String {
  [
    agentAppPath,
    bundlePlugInsSubpath,
    providerBundleName,
    bundleExecutableSubpath,
    providerBinaryName,
  ]
  .joined(separator: "/")
}

/// The name the tunnel provider runs under, used to find it in the guest's process list.
func guestProviderProcessName() -> String {
  providerBinaryName
}

/// The SHA-256 of a file on this host, failing loudly rather than returning nothing,
/// because every caller compares it against the guest's copy.
func guestFileDigest(at path: URL) throws -> String {
  let result = try capture("shasum", ["-a", "256", path.path], echoOutput: false)
  guard result.status == 0 else {
    throw ToolError.failure(
      """
      guest: reading the checksum of \(path.path) failed with status \(result.status); \
      output: \(guestOutputExcerpt(result.output))
      """
    )
  }
  let digest = guestFirstToken(result.output)
  guard !digest.isEmpty else {
    throw ToolError.failure("guest: `shasum` printed no checksum for \(path.path)")
  }
  return digest
}

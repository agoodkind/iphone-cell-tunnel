//
//  BuildIdentityValues.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-15.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .build)

// MARK: - BuildIdentityValues

/// Namesake type so SwiftLint `file_name` matches `BuildIdentityValues.swift`.
enum BuildIdentityValues {}

/// The build-identity values the generated config carries, matching the Makefile's
/// exported variables of the same names.
///
/// Both render paths must produce the same file. The make path substitutes these from
/// Make variables, and this path recomputes them, so a gated build and a decoupled
/// build generate identical output rather than churning a recompile between them. The
/// engine's renderer substitutes named environment variables only and never runs git,
/// which is why the git values are computed rather than read.
func buildIdentityValues() -> [String: String] {
  [
    "MARKETING_VERSION": buildIdentityEnvironmentValue("MARKETING_VERSION", fallback: "0.0.0"),
    "CURRENT_PROJECT_VERSION": buildIdentityEnvironmentValue(
      "CURRENT_PROJECT_VERSION", fallback: "0"),
    "RELEASE_TAG": buildIdentityEnvironmentValue("RELEASE_TAG", fallback: ""),
    "GIT_COMMIT": gitOutput(["rev-parse", "--short", "HEAD"], fallback: "unknown"),
    "GIT_VERSION": gitOutput(["describe", "--tags", "--always", "--dirty"], fallback: "dev"),
    "GIT_DIRTY": gitWorkingTreeIsDirty() ? "true" : "false",
    "GIT_BRANCH": gitOutput(["rev-parse", "--abbrev-ref", "HEAD"], fallback: "unknown"),
  ]
}

private func buildIdentityEnvironmentValue(_ key: String, fallback: String) -> String {
  let raw = ProcessInfo.processInfo.environment[key]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let raw, !raw.isEmpty else {
    return fallback
  }
  return raw
}

// MARK: - Git

/// One git value, or the fallback when git cannot answer. A checkout without history,
/// or without git at all, still generates rather than failing the build.
private func gitOutput(_ arguments: [String], fallback: String) -> String {
  guard let result = runGit(arguments), result.status == 0 else {
    return fallback
  }
  let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.isEmpty {
    return fallback
  }
  return value
}

/// `git diff --quiet` exits non-zero when the working tree carries changes, so a
/// failure to run it reads as clean rather than inventing a dirty build.
private func gitWorkingTreeIsDirty() -> Bool {
  guard let result = runGit(["diff", "--quiet"]) else {
    return false
  }
  return result.status != 0
}

/// Runs one git command, returning nothing when git could not run at all. A checkout
/// without git is a build that still generates, so the failure is reported and the
/// caller falls back rather than stopping the build.
private func runGit(_ arguments: [String]) -> CommandResult? {
  do {
    return try capture("git", arguments, echoOutput: false)
  } catch {
    logger.error(
      """
      build identity git command failed \
      details=\(error.localizedDescription, privacy: .public) recovery=use-fallback-value
      """
    )
    return nil
  }
}

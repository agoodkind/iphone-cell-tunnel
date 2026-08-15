//
//  BuildIdentity.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-15.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BuildIdentity

/// Says which build this binary is, so a downloaded copy, a log line, and a support
/// question can all name the same thing.
///
/// The values are rendered into the generated config at project-generation time. A
/// published build carries the release tag and the marketing and build versions the
/// release pipeline computed. Every other build leaves the tag empty and falls back to
/// what git describes, so a locally built binary still names a commit rather than
/// nothing.
public enum BuildIdentity {
  /// The name this build answers to. A published build reports its release tag; any
  /// other build reports the git description, which carries the nearest tag, the
  /// distance from it, the commit, and a dirty marker.
  public static var version: String {
    if generatedReleaseTag.isEmpty {
      return generatedGitVersion
    }
    return generatedReleaseTag
  }

  /// The version a person sees in the About panel and the Finder, as
  /// `CFBundleShortVersionString` carries it.
  public static var marketingVersion: String {
    generatedMarketingVersion
  }

  /// The build number, as `CFBundleVersion` carries it. macOS compares this when it
  /// decides whether an installed system extension is being upgraded.
  public static var buildNumber: String {
    generatedBuildNumber
  }

  /// The commit this build came from, abbreviated.
  public static var commit: String {
    generatedGitCommit
  }

  /// The branch this build came from.
  public static var branch: String {
    generatedGitBranch
  }

  /// Whether the working tree carried uncommitted changes when the project was
  /// generated. A true value means the commit alone does not reproduce this binary.
  public static var isDirty: Bool {
    generatedGitDirty == "true"
  }

  /// One line naming the build, without a label, for a report that already names the
  /// field it sits in.
  public static var details: String {
    var line = version
    line += " (\(marketingVersion) build \(buildNumber))"
    line += " commit \(commit)"
    line += " branch \(branch)"
    if isDirty {
      line += " dirty"
    }
    return line
  }

  /// The labelled line the command-line tool prints. The release smoke check reads it
  /// by looking for the word `version:` followed by the release tag, so the label comes
  /// first and the tag follows it unabbreviated.
  public static var summary: String {
    "version: \(details)"
  }
}

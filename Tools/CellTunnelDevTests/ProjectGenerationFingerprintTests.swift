//
//  ProjectGenerationFingerprintTests.swift
//  CellTunnelDevTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import CellTunnelDev

// MARK: - ProjectGenerationFingerprintTests

/// Drives the digest that decides whether the Xcode project needs regenerating.
///
/// The project manifest names directories rather than files, so the digest has to
/// notice a file arriving or leaving and ignore a file being edited. Each test builds a
/// real directory tree and reads the digest the build path reads.
@Suite("Project generation file set")
struct ProjectGenerationFingerprintTests {
  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("celltunnel-fingerprint-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// A pull that adds a source file must force the project to regenerate, because the
  /// generated project would otherwise compile a file that uses a type without the file
  /// that declares it.
  @Test("a new file changes the digest")
  func newFileChangesTheDigest() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("enum Existing {}", to: root.appendingPathComponent("Existing.swift"))

    let before = try projectGenerationFileSetDigest(roots: [root])
    try write("enum Arrived {}", to: root.appendingPathComponent("Arrived.swift"))
    let after = try projectGenerationFileSetDigest(roots: [root])

    #expect(before != after)
  }

  /// Editing a file leaves the generated project correct, so it must not force a
  /// regeneration that would produce an identical project on every build.
  @Test("editing a file leaves the digest alone")
  func editingAFileLeavesTheDigestAlone() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Edited.swift")
    try write("enum Edited {}", to: file)

    let before = try projectGenerationFileSetDigest(roots: [root])
    try write("enum Edited { static let added = 1 }", to: file)
    let after = try projectGenerationFileSetDigest(roots: [root])

    #expect(before == after)
  }

  @Test("deleting a file changes the digest")
  func deletingAFileChangesTheDigest() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let removed = root.appendingPathComponent("Removed.swift")
    try write("enum Kept {}", to: root.appendingPathComponent("Kept.swift"))
    try write("enum Removed {}", to: removed)

    let before = try projectGenerationFileSetDigest(roots: [root])
    try FileManager.default.removeItem(at: removed)
    let after = try projectGenerationFileSetDigest(roots: [root])

    #expect(before != after)
  }

  /// A rename keeps the file count and the contents, so a digest built from either
  /// would miss it while the generated project's file list changed.
  @Test("renaming a file changes the digest")
  func renamingAFileChangesTheDigest() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Original.swift")
    try write("enum Subject {}", to: original)

    let before = try projectGenerationFileSetDigest(roots: [root])
    try FileManager.default.moveItem(
      at: original, to: root.appendingPathComponent("Renamed.swift"))
    let after = try projectGenerationFileSetDigest(roots: [root])

    #expect(before != after)
  }

  /// The manifest globs nested directories, so a file added several levels down has to
  /// count the same as one at the top.
  @Test("a file in a nested directory counts")
  func aFileInANestedDirectoryCounts() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("enum Top {}", to: root.appendingPathComponent("Top.swift"))

    let before = try projectGenerationFileSetDigest(roots: [root])
    try write(
      "enum Nested {}",
      to: root.appendingPathComponent("Views/Detail/Nested.swift"))
    let after = try projectGenerationFileSetDigest(roots: [root])

    #expect(before != after)
  }

  /// A checkout can omit an optional directory, and generation still has to run rather
  /// than fail on the missing path.
  @Test("a missing root contributes nothing")
  func aMissingRootContributesNothing() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("enum Present {}", to: root.appendingPathComponent("Present.swift"))
    let absent = root.appendingPathComponent("does-not-exist")

    let withAbsent = try projectGenerationFileSetDigest(roots: [root, absent])
    let withoutAbsent = try projectGenerationFileSetDigest(roots: [root])

    #expect(withAbsent == withoutAbsent)
  }
}

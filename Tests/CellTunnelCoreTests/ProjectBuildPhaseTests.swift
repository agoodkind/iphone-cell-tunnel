//
//  ProjectBuildPhaseTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-17.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

// MARK: - ProjectBuildPhaseTests

struct ProjectBuildPhaseTests {
  @Test func renderPhasesUseConfiguredSwiftMkBinary() throws {
    let testFileURL = URL(fileURLWithPath: #filePath)
    let repositoryRoot =
      testFileURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let projectURL = repositoryRoot.appendingPathComponent("Project.swift")
    let project = try String(contentsOf: projectURL, encoding: .utf8)
    let configuredCommand = #""${SWIFT_MK_BIN:-$SRCROOT/.make/swift-mk}" render-batch"#

    #expect(project.components(separatedBy: configuredCommand).count - 1 == 2)
  }
}

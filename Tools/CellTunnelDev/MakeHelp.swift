//
//  MakeHelp.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-21.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Constants

private let makeHelpNameColumnWidth = 40

// MARK: - MakeHelpEntry

/// One Make target the Makefile routes into CellTunnelDev, with the one-line
/// description `make help` prints for it.
private struct MakeHelpEntry {
  let name: String
  let summary: String
}

// MARK: - Catalog

/// Project Make targets owned here so the Makefile stays a thin router and does
/// not duplicate help text.
private let makeHelpEntries: [MakeHelpEntry] = [
  MakeHelpEntry(name: "build-mac", summary: "build the Mac agent"),
  MakeHelpEntry(name: "build-catalyst", summary: "build the Mac Catalyst app"),
  MakeHelpEntry(name: "build-iphone", summary: "build the iPhone app for a device"),
  MakeHelpEntry(name: "build-iphone-sim", summary: "build the iPhone app for the simulator"),
  MakeHelpEntry(name: "build-daemon", summary: "build the Mac agent daemon only"),
  MakeHelpEntry(name: "run-catalyst", summary: "build, install, and launch the Mac Catalyst app"),
  MakeHelpEntry(name: "run-iphone", summary: "build, install, and launch the iPhone app on a device"),
  MakeHelpEntry(
    name: "run-iphone-sim",
    summary: "build, install, and launch the iPhone app in the simulator"),
  MakeHelpEntry(name: "install-mac", summary: "install the Mac agent into /Applications/CellTunnel"),
  MakeHelpEntry(name: "iphone-install", summary: "install and launch the iPhone app"),
  MakeHelpEntry(
    name: "relay-up WG_CONFIG=<path>",
    summary: "bring the relay tunnel up end to end"),
  MakeHelpEntry(
    name: "relay-reload WG_CONFIG=<path>",
    summary: "reload the running tunnel config in place"),
  MakeHelpEntry(name: "relay-status", summary: "print tunnel status with a drift verdict"),
  MakeHelpEntry(name: "relay-down", summary: "stop the relay tunnel"),
  MakeHelpEntry(
    name: "mac-logs",
    summary: "show or stream Mac agent and tunnel-provider logs"),
  MakeHelpEntry(
    name: "iphone-logs",
    summary: "show the iPhone unified log for the project subsystem"),
  MakeHelpEntry(name: "format", summary: "format Swift sources via CellTunnelDev"),
  MakeHelpEntry(name: "smoke", summary: "print the manual smoke sequence (not yet automated)"),
  MakeHelpEntry(name: "logs", summary: "print how to open Mac and iPhone log streams"),
]

// MARK: - make-help

/// Prints the Cell Tunnel Make section in the same column layout as swift.mk help.
func printMakeHelp() {
  var lines: [String] = ["", "Cell Tunnel:"]
  for entry in makeHelpEntries {
    let paddedName = entry.name.padding(
      toLength: makeHelpNameColumnWidth,
      withPad: " ",
      startingAt: 0)
    lines.append("  \(paddedName) \(entry.summary)")
  }
  FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
}

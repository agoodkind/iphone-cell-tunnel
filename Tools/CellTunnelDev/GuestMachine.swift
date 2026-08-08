//
//  GuestMachine.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let guestMachineLogger = CellTunnelLog.logger(category: .build)
private let guestBootArgument = "amfi_get_out_of_my_way=1"

let guestDefaultUser = "admin"

// MARK: - GuestMachine

/// A Mac this run can test on: reachable over one key login, carrying the developer
/// tools the phone half needs, and booting so that a development-signed agent survives
/// launch.
struct GuestMachine {
  let address: String
  let shell: GuestShell
}

// MARK: - Readiness

/// One thing the machine must already have, and what to do when it does not.
private struct GuestRequirement {
  let name: String
  let remedy: String
}

/// Confirm the machine is ready, and refuse with everything that is missing when it is
/// not. Nothing here changes the machine.
///
/// This runs before anything is built, because every requirement is knowable in the
/// first seconds and the alternative is three signed builds and a transfer spent before
/// the run discovers it cannot finish.
///
/// The machine is not prepared here on purpose. Installing a key and changing boot
/// arguments are decisions about someone else's Mac, and two of the three only make
/// sense on a machine that is disposable.
func prepareGuestMachine(address: String, user: String) throws -> GuestMachine {
  let shell = try guestShell(address: address, user: user)
  var missing: [GuestRequirement] = []

  if let loginFailure = shell.loginFailure() {
    // Nothing else can be read without a login, so this is the whole report.
    throw ToolError.failure(
      """
      guest: no key login to \(shell.destination): \(loginFailure)

      This run reads and writes over one ssh connection and never types a password. \
      Authorize \(shell.identityFile.path).pub on that Mac, for example by running \
      `ssh-copy-id -i \(shell.identityFile.path).pub \(shell.destination)` once from here.
      """
    )
  }
  printToolOutput("guest: key login works for \(shell.destination)")

  missing.append(contentsOf: try guestMissingSimulatorRequirements(shell: shell))
  if try !guestBootsWithoutEntitlementEnforcement(shell: shell) {
    missing.append(
      GuestRequirement(
        name: "the boot argument \(guestBootArgument) in effect",
        remedy:
          "run `sudo nvram boot-args=\"\(guestBootArgument)\"` on that Mac and reboot it; "
          + "the reboot is the part that matters, because this reads the arguments the "
          + "kernel actually booted with rather than what is stored for next time. "
          + "Without it a development-signed agent is killed at launch with "
          + "OS_REASON_CODESIGNING, and setting it needs System Integrity Protection off, "
          + "so do this only on a machine you are willing to weaken"
      )
    )
  }

  guard missing.isEmpty else {
    let report =
      missing
      .map { requirement in "  missing: \(requirement.name)\n  fix: \(requirement.remedy)" }
      .joined(separator: "\n\n")
    throw ToolError.failure(
      """
      guest: \(shell.destination) is not ready, and nothing was built or copied.

      \(report)
      """
    )
  }

  guestMachineLogger.notice("guest machine ready address=\(address, privacy: .public)")
  printToolOutput("guest: \(shell.destination) has developer tools and the boot argument")
  return GuestMachine(address: address, shell: shell)
}

/// What the machine is missing before it can run the phone half, in the order a person
/// would fix them: the tool first, then something for it to boot.
private func guestMissingSimulatorRequirements(
  shell: GuestShell
) throws -> [GuestRequirement] {
  guard try guestHasSimulatorTooling(shell: shell) else {
    guestMachineLogger.notice("guest readiness found no simctl recovery=report-missing")
    return [
      GuestRequirement(
        name: "the iOS simulator command line tool (`xcrun simctl`)",
        remedy:
          "install Xcode on that Mac and select it with `sudo xcode-select -s <Xcode path>`; "
          + "a Mac without it can run the agent but has nowhere to run the phone half"
      )
    ]
  }
  guard try guestHasSimulatorRuntime(shell: shell) else {
    guestMachineLogger.notice(
      "guest readiness found simctl but no iOS runtime recovery=report-missing")
    return [
      GuestRequirement(
        name: "an installed iOS simulator runtime",
        remedy:
          "install one on that Mac with `xcodebuild -downloadPlatform iOS`; the tool is "
          + "present but there is no iOS to boot, which otherwise fails only after "
          + "everything has been built and copied"
      )
    ]
  }
  guestMachineLogger.debug("guest readiness found simctl and an iOS runtime")
  return []
}

/// Whether the machine has the simulator command line tool at all.
private func guestHasSimulatorTooling(shell: GuestShell) throws -> Bool {
  try shell.captureRemote("xcrun simctl help").status == 0
}

/// Whether the machine has an iOS the simulator can boot.
///
/// Asked separately from the tool, because Xcode installs without a runtime and the tool
/// then works perfectly while having no iOS to run the phone half on.
private func guestHasSimulatorRuntime(shell: GuestShell) throws -> Bool {
  let result = try shell.captureRemote("xcrun simctl list runtimes iOS")
  guard result.status == 0 else {
    return false
  }
  return result.output.contains("iOS")
}

/// Whether the machine is running with entitlement enforcement off right now.
///
/// A Mac that is not a registered device kills a development-signed agent at launch
/// without this. The kernel's own boot arguments are what decide that, so they are what
/// is read: the stored `nvram` value is what the machine will boot with next time, and a
/// machine where it was set but never rebooted would pass a check of that value and then
/// kill the agent anyway.
private func guestBootsWithoutEntitlementEnforcement(shell: GuestShell) throws -> Bool {
  let result = try shell.captureRemote("sysctl -n kern.bootargs")
  guard result.status == 0 else {
    return false
  }
  return result.output.contains(guestBootArgument)
}

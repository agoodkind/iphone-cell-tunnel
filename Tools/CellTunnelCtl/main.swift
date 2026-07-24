//
//  main.swift
//  CellTunnelCtl
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)
private let helpSubcommand = "--help"
private let helpShortSubcommand = "-h"

@main
enum CellTunnelCtl {
  static func main() async {
    CellTunnelLog.bootstrap()
    let arguments = Array(CommandLine.arguments.dropFirst())
    logger.notice(
      "celltunnelctl invoked argumentCount=\(arguments.count, privacy: .public)")

    if arguments.isEmpty {
      printUsage()
      return
    }

    if arguments.first == helpSubcommand || arguments.first == helpShortSubcommand {
      printUsage()
      return
    }

    let client = AgentClient()
    do {
      let action = try TunnelControlCLIAction.parse(arguments: arguments)
      let executor = TunnelControlCLIExecutor(
        client: client,
        probeRunner: ProcessSmokeProbeRunner()
      )
      let output = try await executor.run(action: action)
      if !output.isEmpty {
        FileHandle.standardOutput.write(Data((output + "\n").utf8))
      }
      await client.shutdown()
    } catch {
      await client.shutdown()
      emit(error: error)
      exit(1)
    }
  }
}

private func printUsage() {
  let usage = """
    usage: celltunnelctl <command> [options]

    commands:
      status                       Print current tunnel daemon status.
      check                        Print environment check report.
      peers                        List dialed-in peers the Mac can route through.
      select <n>                   Select the egress peer by 1-based index from peers.
      start --config <path>        Start the tunnel using the given WireGuard config.
                                   Optional: --relay <host:port>.
      smoke --config <path> --peer <n>
                                   Start pairing, wait for peers, select, stop,
                                   start, wait for routes, then ping/curl.
                                   Optional: --relay <host:port>.
      stop                         Stop the tunnel.
      reset                        Remove the saved Mac VPN configuration.
      configs list                 List the agent's config library.
      configs activate <name|id>   Activate a stored config and start the tunnel.
      configs rename <id> <name>   Rename a stored config.
      configs delete <id>          Delete a stored config (stops the tunnel if active).
      configs import <path>        Import, activate, and start a WireGuard config file.
      --help, -h                   Print this help text.
    """
  FileHandle.standardOutput.write(Data((usage + "\n").utf8))
}

private func emit(error: Error) {
  if let daemonError = error as? TunnelDaemonError {
    FileHandle.standardError.write(Data("\(daemonError.renderedOutput)\n".utf8))
    return
  }
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
}

// MARK: - ProcessSmokeProbeRunner

private struct ProcessSmokeProbeRunner: SmokeProbeRunner {
  private let timeoutSeconds: TimeInterval

  init(timeoutSeconds: TimeInterval = 60) {
    self.timeoutSeconds = timeoutSeconds
  }

  func run(executable: String, arguments: [String]) throws {
    logger.notice(
      """
      smoke probe start executable=\(executable, privacy: .public) \
      argumentCount=\(arguments.count, privacy: .public)
      """
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    let rendered = ([executable] + arguments).joined(separator: " ")
    try process.run()

    let timedOut = CancellationFlag()
    let timeoutSource = DispatchSource.makeTimerSource(queue: .global())
    timeoutSource.schedule(deadline: .now() + timeoutSeconds)
    timeoutSource.setEventHandler {
      guard process.isRunning else {
        return
      }
      timedOut.cancel()
      process.terminate()
    }
    timeoutSource.resume()
    process.waitUntilExit()
    timeoutSource.cancel()

    if timedOut.isCancelled {
      logger.error(
        """
        smoke probe timed out executable=\(executable, privacy: .public) \
        timeoutSeconds=\(Int(timeoutSeconds), privacy: .public) recovery=throw
        """
      )
      throw TunnelDaemonError.transportFailure(
        "\(rendered) timed out after \(Int(timeoutSeconds))s")
    }
    let status = process.terminationStatus
    if status == 0 {
      logger.notice(
        "smoke probe ok executable=\(executable, privacy: .public) status=0")
      return
    }
    // curl exit 60 is SSL peer certificate / hostname mismatch. An IP-literal HTTPS
    // probe still proves TCP through the tunnel when the certificate does not name
    // that address (per AGENTS.md TCP smoke guidance).
    if executable == "curl", status == curlSSLCertificateProblemExitStatus {
      logger.notice(
        """
        smoke probe accepted curl TLS name mismatch executable=\(executable, privacy: .public) \
        status=\(status, privacy: .public)
        """
      )
      return
    }
    logger.error(
      """
      smoke probe failed executable=\(executable, privacy: .public) \
      status=\(status, privacy: .public) recovery=throw
      """
    )
    throw TunnelDaemonError.transportFailure(
      "\(rendered) failed with status \(status)")
  }
}

private let curlSSLCertificateProblemExitStatus: Int32 = 60

// MARK: - CancellationFlag

private final class CancellationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

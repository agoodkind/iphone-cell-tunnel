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
      let executor = TunnelControlCLIExecutor(client: client)
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
      peers                        List discovered peers.
      select <n|serviceID>         Select a peer by 1-based index or service id.
      start --config <path>        Start the tunnel using the given WireGuard config.
                                   Optional: --relay <host:port>.
      stop                         Stop the tunnel.
      reset                        Remove the saved Mac VPN configuration.
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

import CellTunnelCore
import CellTunnelLog
import Foundation

private let helpSubcommand = "--help"
private let helpShortSubcommand = "-h"

@main
enum CellTunnelCtl {
    static func main() async {
        CellTunnelLog.bootstrap()
        let arguments = Array(CommandLine.arguments.dropFirst())

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
                print(output)
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
          start-discovery              Start relay discovery on the agent.
          stop-discovery               Stop relay discovery on the agent.
          discover                     Start discovery and poll until a service is ready.
          probe                        Run status + start-discovery + list-relay-services in order.
          select <serviceID>           Select a discovered relay service.
          start --config <path>        Start the tunnel using the given WireGuard config.
                                       Optional: --relay <host:port>.
          stop                         Stop the tunnel.
          --help, -h                   Print this help text.
        """
    print(usage)
}

private func emit(error: Error) {
    if let daemonError = error as? TunnelDaemonError {
        FileHandle.standardError.write(Data("\(daemonError.renderedOutput)\n".utf8))
        return
    }
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
}

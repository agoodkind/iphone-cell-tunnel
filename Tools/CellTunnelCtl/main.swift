import CellTunnelCore
import CellTunnelLog
import Foundation

@main
enum CellTunnelCtl {
    static func main() async {
        CellTunnelLog.bootstrap()
        let client = TunnelControlClient()

        do {
            let action = try TunnelControlCLIAction.parse(
                arguments: Array(CommandLine.arguments.dropFirst()))
            let executor = TunnelControlCLIExecutor(client: client)
            let output = try await executor.run(action: action)
            if !output.isEmpty {
                print(output)
            }
            await client.shutdown()
        } catch {
            await client.shutdown()
            if let daemonError = error as? TunnelDaemonError {
                FileHandle.standardError.write(Data("\(daemonError.renderedOutput)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            }
            exit(1)
        }
    }
}

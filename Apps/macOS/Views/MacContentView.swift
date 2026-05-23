import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)

struct MacContentView: View {
    @Bindable var tunnelStore: MacTunnelStore

    var body: some View {
        NavigationSplitView {
            List(selection: $tunnelStore.selection) {
                Label("Tunnel", systemImage: "network")
                    .tag(MacTunnelSection.tunnel)
                Label("Cellular", systemImage: "antenna.radiowaves.left.and.right")
                    .tag(MacTunnelSection.cellular)
                Label("Daemon", systemImage: "terminal")
                    .tag(MacTunnelSection.daemon)
            }
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusGrid
                    controls
                    daemonOutput
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cell Tunnel")
                .font(.largeTitle.bold())
            Text("Dual-stack relay through a foreground iPhone cellular path.")
                .foregroundStyle(.secondary)
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            GridRow {
                Text("Tunnel")
                    .foregroundStyle(.secondary)
                Text(tunnelStore.tunnelStateDescription)
            }
            GridRow {
                Text("Peer")
                    .foregroundStyle(.secondary)
                Text(tunnelStore.peerName)
            }
            GridRow {
                Text("Routes")
                    .foregroundStyle(.secondary)
                Text(tunnelStore.routeStateDescription)
            }
            GridRow {
                Text("Counters")
                    .foregroundStyle(.secondary)
                Text(tunnelStore.counterDescription)
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Start") {
                logger.notice("mac content start command invoked")
                tunnelStore.start()
            }
            .keyboardShortcut("r")

            Button("Stop") {
                logger.notice("mac content stop command invoked")
                tunnelStore.stop()
            }
            .keyboardShortcut(".")

            Button("Refresh") {
                logger.notice("mac content refresh command invoked")
                tunnelStore.refreshStatus()
            }
        }
    }

    @ViewBuilder
    private var daemonOutput: some View {
        if !tunnelStore.daemonOutput.isEmpty {
            Text(tunnelStore.daemonOutput)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    MacContentView(tunnelStore: MacTunnelStore())
}

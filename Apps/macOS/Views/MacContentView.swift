import CellTunnelLog
import SwiftUI
import UniformTypeIdentifiers

private let logger = CellTunnelLog.logger(category: .app)

struct MacContentView: View {
    @Bindable var tunnelStore: MacTunnelStore
    @State private var isChoosingWireGuardConfig = false

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
                    settings
                    relayDiscovery
                    controls
                    daemonOutput
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fileImporter(
            isPresented: $isChoosingWireGuardConfig,
            allowedContentTypes: [.text, .data],
            allowsMultipleSelection: false
        ) { result in
            handleWireGuardConfigImport(result)
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
                Text("Helper")
                    .foregroundStyle(.secondary)
                Text(tunnelStore.helperStateDescription)
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
            GridRow {
                Text("Last Error")
                    .foregroundStyle(.secondary)
                Text(tunnelStore.lastDaemonError ?? "None")
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.headline)
            HStack(spacing: 10) {
                TextField("WireGuard config path", text: $tunnelStore.wireGuardConfigPath)
                    .textFieldStyle(.roundedBorder)
                Button {
                    logger.notice("mac content choose wireguard config invoked")
                    isChoosingWireGuardConfig = true
                } label: {
                    Label("Choose", systemImage: "folder")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Config")
                        .foregroundStyle(.secondary)
                    Text(tunnelStore.wireGuardConfigDescription)
                }
                GridRow {
                    Text("Relay")
                        .foregroundStyle(.secondary)
                    Text(tunnelStore.relayEndpointDescription)
                }
            }
            .font(.system(.callout, design: .monospaced))
        }
    }

    private var relayDiscovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Cellular Relay")
                    .font(.headline)
                Text(tunnelStore.relayDiscoveryStateDescription)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    logger.notice("mac content discover relay command invoked")
                    tunnelStore.startRelayDiscovery()
                } label: {
                    Label("Discover", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    logger.notice("mac content stop relay discovery command invoked")
                    tunnelStore.stopRelayDiscovery()
                } label: {
                    Label("Stop", systemImage: "stop")
                }
            }

            if tunnelStore.discoveredRelayServices.isEmpty {
                Text("No resolved _cellrelay._tcp services")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tunnelStore.discoveredRelayServices) { service in
                        Button {
                            logger.notice("mac content relay service selection invoked")
                            tunnelStore.selectRelayService(service)
                        } label: {
                            HStack {
                                Text(service.displayName)
                                Spacer()
                                if tunnelStore.selectedRelayServiceID == service.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                logger.notice("mac content start command invoked")
                tunnelStore.start()
            } label: {
                Label("Start", systemImage: "play")
            }
            .keyboardShortcut("r")

            Button {
                logger.notice("mac content stop command invoked")
                tunnelStore.stop()
            } label: {
                Label("Stop", systemImage: "stop")
            }
            .keyboardShortcut(".")

            Button {
                logger.notice("mac content refresh command invoked")
                tunnelStore.refreshStatus()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                logger.notice("mac content install helper command invoked")
                tunnelStore.installHelper()
            } label: {
                Label("Install Helper", systemImage: "plus.circle")
            }

            Button {
                logger.notice("mac content remove helper command invoked")
                tunnelStore.uninstallHelper()
            } label: {
                Label("Remove Helper", systemImage: "minus.circle")
            }

            Button {
                logger.notice("mac content helper approval command invoked")
                tunnelStore.openHelperSettings()
            } label: {
                Label("Approve", systemImage: "checkmark.seal")
            }
        }
    }

    private func handleWireGuardConfigImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                logger.error(
                    "wireguard config import failed error=missing-selection recovery=choose-again")
                return
            }
            tunnelStore.selectWireGuardConfigFile(url)
            logger.notice("wireguard config import completed")
        } catch {
            tunnelStore.daemonOutput = error.localizedDescription
            tunnelStore.lastDaemonError = error.localizedDescription
            logger.error(
                "wireguard config import failed error=\(error.localizedDescription, privacy: .public)"
            )
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

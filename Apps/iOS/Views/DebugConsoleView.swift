#if DEBUG
    import CellTunnelCore
    import CellTunnelLog
    import SwiftUI

    private let logger = CellTunnelLog.logger(category: .relay)
    private let endpointFieldPlaceholder = "host:port"
    private let valueNone = "None"

    /// DEBUG-only developer console for live debugging against the real relay
    /// infra: the iOS relay listener, the Mac control/data link, and the cellular
    /// egress. Most rows read `PhoneRelayController`'s `@Observable` state directly
    /// so they auto-update; the buttons drive real network interactions and report
    /// their latest outcome inline. Nothing here is a synthetic unit test.
    struct DebugConsoleView: View {
        let relayController: PhoneRelayController

        @Environment(\.dismiss) private var dismiss
        @State private var endpointText = ""
        @State private var restartResult = ""
        @State private var endpointResult = ""
        @State private var cellularProbeResult = ""
        @State private var loopbackResult = ""
        @State private var isProbingCellular = false
        @State private var isRunningLoopback = false

        var body: some View {
            NavigationStack {
                List {
                    relaySection
                    macLinkSection
                    cellularSection
                    diagnosticsSection
                    countersSection
                    backgroundTunnelSection
                }
                .navigationTitle("Developer")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        // MARK: - Sections

        @ViewBuilder private var relaySection: some View {
            Section("Relay") {
                LabeledContent("State", value: relayController.relayStateDescription)
                LabeledContent("Running", value: yesNo(relayController.isRunning))
                LabeledContent("Peer", value: relayController.connectedPeerName ?? valueNone)
                LabeledContent("Last Error", value: relayController.lastError ?? valueNone)
                Button {
                    restartRelay()
                } label: {
                    Label("Restart relay", systemImage: "arrow.clockwise")
                }
                resultCaption(restartResult)
            }
        }

        @ViewBuilder private var macLinkSection: some View {
            Section("Mac Link") {
                LabeledContent(
                    "Peer connected",
                    value: yesNo(relayController.connectedPeerName != nil)
                )
                LabeledContent("Advertising", value: yesNo(relayController.isRunning))
                TextField(endpointFieldPlaceholder, text: $endpointText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    setServerEndpoint()
                } label: {
                    Label("Set server endpoint", systemImage: "antenna.radiowaves.left.and.right")
                }
                resultCaption(endpointResult)
            }
        }

        @ViewBuilder private var cellularSection: some View {
            Section("Cellular") {
                LabeledContent("Path", value: yesNo(relayController.cellularPath.isSatisfied))
                LabeledContent("Interface", value: relayController.cellularInterfaceDescription)
                LabeledContent("IPv4", value: yesNo(relayController.cellularPath.supportsIPv4))
                LabeledContent("IPv6", value: yesNo(relayController.cellularPath.supportsIPv6))
                Button {
                    probeCellular()
                } label: {
                    Label("Probe server over cellular", systemImage: "cellularbars")
                }
                .disabled(isProbingCellular)
                resultCaption(cellularProbeResult)
            }
        }

        @ViewBuilder private var diagnosticsSection: some View {
            Section("Diagnostics") {
                Button {
                    runLoopback()
                } label: {
                    Label("Local link loopback", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isRunningLoopback)
                resultCaption(loopbackResult)
            }
        }

        @ViewBuilder private var countersSection: some View {
            Section("Counters") {
                counterRow("From Mac", relayController.counters.wireGuardDatagramsFromMac)
                counterRow("To Mac", relayController.counters.wireGuardDatagramsToMac)
                counterRow("To Server", relayController.counters.wireGuardDatagramsToServer)
                counterRow("From Server", relayController.counters.wireGuardDatagramsFromServer)
                counterRow("Dropped", relayController.counters.droppedWireGuardDatagrams)
                counterRow("Bytes In", relayController.counters.relayBytesIn)
                counterRow("Bytes Out", relayController.counters.relayBytesOut)
                throughputRow("Upload", relayController.uploadMbps)
                throughputRow("Download", relayController.downloadMbps)
            }
        }

        @ViewBuilder private var backgroundTunnelSection: some View {
            Section("Background Tunnel") {
                LabeledContent("iOS NetworkExtension", value: "Not yet built")
            }
        }

        // MARK: - Row helpers

        @ViewBuilder private func counterRow(_ title: String, _ value: UInt64) -> some View {
            LabeledContent(title) {
                Text(value.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        @ViewBuilder private func throughputRow(_ title: String, _ value: Double) -> some View {
            LabeledContent(title) {
                Text(String(format: "%.1f Mbps", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        @ViewBuilder private func resultCaption(_ text: String) -> some View {
            if !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        private func yesNo(_ value: Bool) -> String {
            value ? "Yes" : "No"
        }

        // MARK: - Actions

        private func restartRelay() {
            logger.notice("developer console restart relay requested")
            relayController.stop()
            relayController.start()
            restartResult = "Relay restarted"
        }

        private func setServerEndpoint() {
            logger.notice("developer console set server endpoint requested")
            guard let endpoint = DebugConsoleProbes.parseEndpoint(from: endpointText) else {
                endpointResult = "Could not parse \"\(endpointText)\""
                return
            }
            relayController.forwarder.setServerEndpoint(endpoint)
            endpointResult = "Set \(endpoint.host):\(endpoint.port)"
        }

        private func probeCellular() {
            logger.notice("developer console cellular probe requested")
            guard let endpoint = DebugConsoleProbes.parseEndpoint(from: endpointText) else {
                cellularProbeResult = "Enter host:port first"
                return
            }
            isProbingCellular = true
            cellularProbeResult = "Probing..."
            Task {
                let result = await DebugConsoleProbes.probeServerOverCellular(endpoint: endpoint)
                await MainActor.run {
                    cellularProbeResult = result.detail
                    isProbingCellular = false
                }
            }
        }

        private func runLoopback() {
            logger.notice("developer console loopback probe requested")
            isRunningLoopback = true
            loopbackResult = "Running..."
            Task {
                let result = await DebugConsoleProbes.runLocalLinkLoopback()
                await MainActor.run {
                    let status = result.passed ? "Pass" : "Fail"
                    loopbackResult = "\(status): \(result.detail)"
                    isRunningLoopback = false
                }
            }
        }
    }
#endif

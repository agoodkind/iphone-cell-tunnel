import SwiftUI

private let peerPlaceholder = "None"
private let readyStateText = "Ready"

struct PhoneContentView: View {
    @Bindable var relayController: PhoneRelayController

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text(status.text)
                            .foregroundStyle(status.color)
                            .fontWeight(.semibold)
                    } label: {
                        Label("Status", systemImage: status.symbol)
                            .foregroundStyle(status.color)
                    }
                }

                Section("Throughput") {
                    LabeledContent("Upload") {
                        Text(String(format: "%.1f Mbps", relayController.uploadMbps))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Download") {
                        Text(String(format: "%.1f Mbps", relayController.downloadMbps))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Connection") {
                    LabeledContent(
                        "Cellular",
                        value: relayController.cellularInterfaceDescription
                    )
                    LabeledContent(
                        "Peer",
                        value: relayController.connectedPeerName ?? peerPlaceholder
                    )
                    LabeledContent("Dropped") {
                        Text(relayController.counters.droppedWireGuardDatagrams.formatted())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Cell Tunnel")
            .listStyle(.insetGrouped)
        }
    }

    private var status: RelayStatus {
        if relayController.lastError != nil {
            return RelayStatus(text: "Error", color: .red, symbol: "exclamationmark.triangle.fill")
        }
        if relayController.isRunning, relayController.relayStateDescription == readyStateText {
            return RelayStatus(text: "Relay active", color: .green, symbol: "checkmark.circle.fill")
        }
        if relayController.isRunning {
            return RelayStatus(
                text: relayController.relayStateDescription,
                color: .orange,
                symbol: "arrow.triangle.2.circlepath"
            )
        }
        return RelayStatus(text: "Stopped", color: .secondary, symbol: "pause.circle.fill")
    }
}

private struct RelayStatus {
    let text: String
    let color: Color
    let symbol: String
}

#Preview {
    PhoneContentView(relayController: PhoneRelayController())
}

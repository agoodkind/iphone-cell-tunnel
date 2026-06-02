//
//  PhoneContentView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - Constants

private let peerPlaceholder = "None"
private let readyStateText = "Ready"

// MARK: - Status screen

struct PhoneContentView: View {
    @Bindable var relayController: RelayController
    @State private var isPresentingDebugConsole = false

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
            .debugConsoleToolbar(
                isPresented: $isPresentingDebugConsole,
                relayController: relayController
            )
        }
    }

    private var status: RelayStatus {
        // A working relay wins over a momentary error. A transient mDNSResponder
        // restart fails every Bonjour advertiser on the device for a moment and
        // self-heals within seconds, so it must not flip a forwarding relay to a
        // red failure. The error is surfaced only when the relay is not running,
        // and as a recoverable warning carrying its message, never a bare "Error".
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
        if let lastError = relayController.lastError {
            return RelayStatus(
                text: lastError,
                color: .orange,
                symbol: "exclamationmark.triangle.fill"
            )
        }
        return RelayStatus(text: "Stopped", color: .secondary, symbol: "pause.circle.fill")
    }
}

// MARK: - RelayStatus

private struct RelayStatus {
    let text: String
    let color: Color
    let symbol: String
}

// MARK: - View

extension View {
    #if DEBUG
        @ViewBuilder func debugConsoleToolbar(
            isPresented: Binding<Bool>,
            relayController: RelayController
        ) -> some View {
            toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented.wrappedValue = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
            }
            .sheet(isPresented: isPresented) {
                DebugConsoleView(relayController: relayController)
            }
        }
    #else
        func debugConsoleToolbar(
            isPresented _: Binding<Bool>,
            relayController _: RelayController
        ) -> some View {
            self
        }
    #endif
}

#Preview {
    #if targetEnvironment(macCatalyst)
        PhoneContentView(relayController: RelayController(backend: AgentRelayBackend()))
    #else
        PhoneContentView(relayController: RelayController(backend: PhoneRelayBackend()))
    #endif
}

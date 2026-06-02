//
//  DebugConsoleView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

#if DEBUG
    import CellTunnelCore
    import CellTunnelLog
    import SwiftUI

    private let logger = CellTunnelLog.logger(category: .relay)
    private let endpointFieldPlaceholder = "host:port"
    private let valueNone = "None"

    /// DEBUG-only developer console for live debugging against the real relay
    /// infra. Most rows read `RelayController`'s observable state, which the status
    /// poll fills from the platform backend, so they auto-update. The buttons drive
    /// real interactions and report their latest outcome inline. The console runs on
    /// both platforms: the iPhone reads its on-device tunnel, the Mac reads the
    /// agent over XPC.
    struct DebugConsoleView: View {
        let relayController: RelayController

        @Environment(\.dismiss) private var dismiss
        @State private var endpointText = ""
        @State private var restartResult = ""
        @State private var serverProbeResult = ""
        @State private var isProbingServer = false

        var body: some View {
            NavigationStack {
                List {
                    relaySection
                    macLinkSection
                    cellularSection
                    environmentSection
                    countersSection
                }
                .navigationTitle("Developer")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task {
                await relayController.refreshEnvironmentChecks()
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
            }
        }

        @ViewBuilder private var cellularSection: some View {
            Section("Cellular") {
                LabeledContent("Path", value: yesNo(relayController.cellularPath.isSatisfied))
                LabeledContent("Interface", value: relayController.cellularInterfaceDescription)
                LabeledContent("IPv4", value: yesNo(relayController.cellularPath.supportsIPv4))
                LabeledContent("IPv6", value: yesNo(relayController.cellularPath.supportsIPv6))
                TextField(endpointFieldPlaceholder, text: $endpointText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    probeServer()
                } label: {
                    Label("Probe server", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(isProbingServer)
                resultCaption(serverProbeResult)
            }
        }

        @ViewBuilder private var environmentSection: some View {
            if !relayController.environmentChecks.isEmpty {
                Section("Environment") {
                    ForEach(relayController.environmentChecks, id: \.name) { check in
                        LabeledContent(check.name, value: check.value)
                    }
                }
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

        // The relay runs in the platform backend, so a restart cycles it through the
        // controller rather than tearing down an in-app forwarder.
        private func restartRelay() {
            logger.notice("developer console restart relay requested")
            Task {
                await relayController.restartRelay()
            }
            restartResult = "Relay restarting"
        }

        private func probeServer() {
            logger.notice("developer console server probe requested")
            guard let endpoint = RelayServerProbe.parseEndpoint(from: endpointText) else {
                serverProbeResult = "Enter host:port first"
                return
            }
            isProbingServer = true
            serverProbeResult = "Probing..."
            Task {
                let result = await relayController.probeServer(endpoint: endpoint)
                isProbingServer = false
                serverProbeResult = result.detail
            }
        }
    }
#endif

import SwiftUI

struct PhoneContentView: View {
    @Bindable var relayController: PhoneRelayController

    var body: some View {
        NavigationStack {
            List {
                Section("Relay") {
                    LabeledContent("State", value: relayController.stateDescription)
                    LabeledContent("Peer", value: relayController.connectedPeerName ?? "None")
                    LabeledContent("Service", value: relayController.serviceDescription)
                }

                Section("Cellular") {
                    LabeledContent("Available", value: relayController.cellularPath.isSatisfied ? "Yes" : "No")
                    LabeledContent("IPv4", value: relayController.cellularPath.supportsIPv4 ? "Yes" : "No")
                    LabeledContent("IPv6", value: relayController.cellularPath.supportsIPv6 ? "Yes" : "No")
                    LabeledContent("Interface", value: relayController.cellularInterfaceDescription)
                }

                Section("Counters") {
                    LabeledContent("TCP", value: relayController.counters.tcpFlows.formatted())
                    LabeledContent("UDP", value: relayController.counters.udpFlows.formatted())
                    LabeledContent("ICMP", value: relayController.counters.icmpFlows.formatted())
                }
            }
            .navigationTitle("Cell Tunnel")
            .toolbar {
                Button(relayController.isRunning ? "Stop" : "Start") {
                    relayController.toggle()
                }
            }
        }
    }
}

#Preview {
    PhoneContentView(relayController: PhoneRelayController())
}

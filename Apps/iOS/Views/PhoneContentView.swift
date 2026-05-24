import SwiftUI

struct PhoneContentView: View {
    @Bindable var relayController: PhoneRelayController

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderBar(isRunning: relayController.isRunning)
                content
            }
        }
        .safeAreaInset(edge: .bottom) {
            RelayActionBar(isRunning: relayController.isRunning) {
                relayController.toggle()
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StatusGrid(items: relayStatusItems)
                cellularSection
                serviceSection
                trafficSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 82)
        }
        .scrollIndicators(.hidden)
    }

    private var relayStatusItems: [StatusTileModel] {
        [
            StatusTileModel(
                title: "Relay",
                value: relayDisplay.title,
                systemImage: relayDisplay.systemImage,
                tint: relayDisplay.tint
            ),
            StatusTileModel(
                title: "Peer",
                value: relayController.connectedPeerName ?? "None",
                systemImage: "macbook",
                tint: relayController.connectedPeerName == nil ? .secondary : .green
            ),
            StatusTileModel(
                title: "WireGuard",
                value: relayController.wireGuardRelayStateDescription,
                systemImage: "lock.shield",
                tint: .blue
            ),
            StatusTileModel(
                title: "Port",
                value: relayController.listenerPortDescription,
                systemImage: "network",
                tint: relayController.listenerPort == nil ? .secondary : .indigo
            ),
        ]
    }

    private var relayDisplay: RelayDisplay {
        RelayDisplay(isRunning: relayController.isRunning, lastError: relayController.lastError)
    }

    private var cellularSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Cellular", systemImage: "antenna.radiowaves.left.and.right")
            StatusGrid(items: cellularStatusItems)
        }
    }

    private var cellularStatusItems: [StatusTileModel] {
        [
            StatusTileModel(
                title: "Path",
                value: relayController.cellularPath.isSatisfied ? "Available" : "Unavailable",
                systemImage: "dot.radiowaves.left.and.right",
                tint: relayController.cellularPath.isSatisfied ? .green : .secondary
            ),
            StatusTileModel(
                title: "Interface",
                value: relayController.cellularInterfaceDescription,
                systemImage: "cellularbars",
                tint: .blue
            ),
            StatusTileModel(
                title: "IPv4",
                value: relayController.cellularPath.supportsIPv4 ? "Ready" : "No Path",
                systemImage: "4.circle",
                tint: relayController.cellularPath.supportsIPv4 ? .green : .secondary
            ),
            StatusTileModel(
                title: "IPv6",
                value: relayController.cellularPath.supportsIPv6 ? "Ready" : "No Path",
                systemImage: "6.circle",
                tint: relayController.cellularPath.supportsIPv6 ? .green : .secondary
            ),
        ]
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "Relay Service", systemImage: "point.3.connected.trianglepath.dotted")
            InfoPanel {
                InfoRow(
                    title: "Bonjour",
                    value: relayController.serviceDescription,
                    systemImage: relayController.isAdvertising ? "bonjour" : "wifi.slash",
                    tint: relayController.isAdvertising ? .green : .secondary
                )
                Divider()
                InfoRow(
                    title: "Name",
                    value: relayController.serviceNameDescription,
                    systemImage: "iphone",
                    tint: .indigo
                )
            }
        }
    }

    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "WireGuard Traffic", systemImage: "lock.shield")
            MetricGrid(metrics: trafficMetrics)
        }
    }

    private var trafficMetrics: [MetricItem] {
        [
            MetricItem(
                title: "To Server",
                value: relayController.counters.wireGuardDatagramsToServer.formatted(),
                detail: relayBytes(relayController.counters.relayBytesIn),
                systemImage: "arrow.up.right"
            ),
            MetricItem(
                title: "To Mac",
                value: relayController.counters.wireGuardDatagramsToMac.formatted(),
                detail: relayBytes(relayController.counters.relayBytesOut),
                systemImage: "arrow.down.left"
            ),
            MetricItem(
                title: "Dropped",
                value: relayController.counters.droppedWireGuardDatagrams.formatted(),
                detail: "Datagrams",
                systemImage: "exclamationmark.triangle"
            ),
        ]
    }
}

private struct RelayDisplay {
    let title: String
    let systemImage: String
    let tint: Color

    init(isRunning: Bool, lastError: String?) {
        if lastError != nil {
            title = "Error"
            systemImage = "exclamationmark.triangle.fill"
            tint = .red
            return
        }

        if isRunning {
            title = "Running"
            systemImage = "bolt.horizontal.circle.fill"
            tint = .green
            return
        }

        title = "Stopped"
        systemImage = "pause.circle.fill"
        tint = .secondary
    }
}

private struct HeaderBar: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cell Tunnel")
                    .font(.title3.weight(.semibold))
                Text("iPhone Relay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            StatusPill(
                title: isRunning ? "Running" : "Stopped",
                tint: isRunning ? .green : .secondary
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct StatusTileModel: Identifiable {
    let id: String
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    init(title: String, value: String, systemImage: String, tint: Color) {
        id = title
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
    }
}

private struct StatusGrid: View {
    let items: [StatusTileModel]

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10
        ) {
            ForEach(items) { item in
                StatusTile(item: item)
            }
        }
    }
}

private struct StatusTile: View {
    let item: StatusTileModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.headline)
                .foregroundStyle(item.tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(item.value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct InfoPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct InfoRow: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 24)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 10)

            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(minHeight: 38)
    }
}

private struct MetricItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    init(title: String, value: String, detail: String, systemImage: String) {
        id = title
        self.title = title
        self.value = value
        self.detail = detail
        self.systemImage = systemImage
    }
}

private struct MetricGrid: View {
    let metrics: [MetricItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            ForEach(metrics) { metric in
                MetricTile(metric: metric)
            }
        }
    }
}

private struct MetricTile: View {
    let metric: MetricItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: metric.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
            Text(metric.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(metric.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(metric.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RelayActionBar: View {
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                isRunning ? "Stop Relay" : "Start Relay",
                systemImage: isRunning ? "stop.fill" : "play.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(isRunning ? .red : .green)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

private struct StatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

private func relayBytes(_ bytes: UInt64) -> String {
    let cappedBytes = min(bytes, UInt64(Int64.max))
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: Int64(cappedBytes))
}

#Preview {
    PhoneContentView(relayController: PhoneRelayController())
}

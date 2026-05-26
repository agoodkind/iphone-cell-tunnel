import CellTunnelCore
import Foundation
import XCTest

final class TunnelControlModelsTests: XCTestCase {
    func testStartSettingsUsesDaemonSelectedRelayByDefault() {
        let settings = TunnelStartSettings(wireGuardConfigPath: "/tmp/wg.conf")

        XCTAssertTrue(settings.isReadyToStart)
        XCTAssertTrue(settings.usesDaemonSelectedRelay)
        XCTAssertFalse(settings.hasLocalRelayEndpoint)
    }

    func testRelayEndpointParsesBracketedIPv6() throws {
        let endpoint = try TunnelRelayEndpoint.parse(argument: "[fd00::44]:51820")

        XCTAssertEqual(endpoint.host, "fd00::44")
        XCTAssertEqual(endpoint.port, 51_820)
        XCTAssertEqual(endpoint.addressFamily, .ipv6)
        XCTAssertEqual(endpoint.socketAddress, "[fd00::44]:51820")
    }

    func testCLIParseStartWithExplicitRelay() throws {
        let action = try TunnelControlCLIAction.parse(
            arguments: ["start", "--config", "/tmp/wg.conf", "--relay", "[fd00::44]:51820"]
        )

        guard case .start(let settings) = action else {
            XCTFail("unexpected action: \(action)")
            return
        }
        XCTAssertEqual(settings.wireGuardConfigPath, "/tmp/wg.conf")
        XCTAssertEqual(settings.relayEndpoint?.socketAddress, "[fd00::44]:51820")
    }

    func testCLIParseProbe() throws {
        let action = try TunnelControlCLIAction.parse(arguments: ["probe"])

        XCTAssertEqual(action, .probe)
    }

    func testCLIParseSelectRequiresServiceID() {
        XCTAssertThrowsError(try TunnelControlCLIAction.parse(arguments: ["select"]))
    }

    func testCLIParseSelectRejectsExtraArguments() {
        XCTAssertThrowsError(
            try TunnelControlCLIAction.parse(arguments: ["select", "relay-1", "extra"])
        )
    }

    func testCLIParseSelectTrimsAndStoresServiceID() throws {
        let action = try TunnelControlCLIAction.parse(arguments: ["select", "  relay-1  "])

        XCTAssertEqual(action, .select(serviceID: "relay-1"))
    }

    func testCLIExecutorDiscoverListsServicesWithoutSelecting() async throws {
        let client = FakeTunnelControlClient()
        let executor = TunnelControlCLIExecutor(client: client)

        let output = try await executor.run(action: .discover)

        XCTAssertEqual(client.events, ["startRelayDiscovery", "listRelayServices"])
        XCTAssertEqual(output, client.listedDiscoverySnapshot.renderedOutput)
    }

    func testCLIExecutorSelectCallsSelectRelayService() async throws {
        let client = FakeTunnelControlClient()
        let executor = TunnelControlCLIExecutor(client: client)

        let output = try await executor.run(action: .select(serviceID: "relay-1"))

        XCTAssertEqual(client.events, ["selectRelayService"])
        XCTAssertEqual(output, client.selectedDiscoverySnapshot.renderedOutput)
    }

    func testCLIExecutorProbeOutputsControlSections() async throws {
        let client = FakeTunnelControlClient()
        let executor = TunnelControlCLIExecutor(client: client)

        let output = try await executor.run(action: .probe)

        XCTAssertEqual(client.events, ["status", "startRelayDiscovery", "listRelayServices"])
        XCTAssertTrue(output.contains("probe=status"))
        XCTAssertTrue(output.contains("probe=start-discovery"))
        XCTAssertTrue(output.contains("probe=list-relay-services"))
    }

    func testStatusSnapshotRendersDiscoverySelection() {
        let endpoint = TunnelRelayEndpoint(host: "fd00::1", port: 5_354, addressFamily: .ipv6)
        let discovery = TunnelDiscoverySnapshot(
            phase: .ready,
            services: [],
            selectedServiceID: "relay-1",
            selectedEndpoint: endpoint,
            lastError: nil
        )
        let snapshot = TunnelDaemonStatusSnapshot(
            running: true,
            routeState: .installed,
            peerState: .wireGuardConfigured,
            ipv4Address: "198.18.0.2",
            ipv6Address: "fd7a:ce11:7a11::2",
            lastError: nil,
            discovery: discovery,
            activeRelayEndpoint: endpoint
        )

        XCTAssertTrue(snapshot.running)
        XCTAssertEqual(snapshot.routeState, .installed)
        XCTAssertEqual(snapshot.peerState, .wireGuardConfigured)
        XCTAssertEqual(snapshot.discovery.selectedServiceID, "relay-1")
        XCTAssertEqual(snapshot.activeRelayEndpoint?.socketAddress, "[fd00::1]:5354")
    }
}

private func makeRelayService(
    serviceID: String,
    serviceName: String,
    host: String,
    endpointHost: String,
    endpointPort: Int,
    isSelected: Bool = false
) -> TunnelRelayService {
    let endpoint = TunnelRelayEndpoint(
        host: endpointHost,
        port: endpointPort,
        addressFamily: .ipv6
    )
    return TunnelRelayService(
        id: serviceID,
        serviceName: serviceName,
        serviceType: "_cellrelay._udp",
        domain: "local.",
        interfaceIndex: 0,
        hostName: host,
        endpoints: [endpoint],
        preferredEndpoint: endpoint,
        isSelected: isSelected
    )
}

private final class FakeTunnelControlClient: TunnelControlClientProtocol, @unchecked Sendable {
    var events: [String] = []
    let startDiscoverySnapshot = TunnelDiscoverySnapshot(
        phase: .browsing,
        services: [],
        selectedServiceID: nil,
        selectedEndpoint: nil,
        lastError: nil
    )
    let listedDiscoverySnapshot = TunnelDiscoverySnapshot(
        phase: .ready,
        services: [
            makeRelayService(
                serviceID: "relay-1",
                serviceName: "CellTunnelPhone",
                host: "iphone.local",
                endpointHost: "fd00::44",
                endpointPort: 51_820
            )
        ],
        selectedServiceID: nil,
        selectedEndpoint: nil,
        lastError: nil
    )
    let selectedDiscoverySnapshot = TunnelDiscoverySnapshot(
        phase: .ready,
        services: [
            makeRelayService(
                serviceID: "relay-1",
                serviceName: "CellTunnelPhone",
                host: "iphone.local",
                endpointHost: "fd00::44",
                endpointPort: 51_820,
                isSelected: true
            )
        ],
        selectedServiceID: "relay-1",
        selectedEndpoint: TunnelRelayEndpoint(host: "fd00::44", port: 51_820, addressFamily: .ipv6),
        lastError: nil
    )

    func status() async -> TunnelDaemonStatusSnapshot {
        await Task.yield()
        events.append("status")
        return TunnelDaemonStatusSnapshot()
    }

    func check() async -> TunnelEnvironmentReport {
        await Task.yield()
        events.append("check")
        return TunnelEnvironmentReport()
    }

    func startTunnel(settings: TunnelStartSettings) async -> TunnelDaemonStatusSnapshot {
        await Task.yield()
        events.append("startTunnel")
        _ = settings
        return TunnelDaemonStatusSnapshot()
    }

    func stopTunnel() async -> TunnelDaemonStatusSnapshot {
        await Task.yield()
        events.append("stopTunnel")
        return TunnelDaemonStatusSnapshot()
    }

    func startRelayDiscovery() async -> TunnelDiscoverySnapshot {
        await Task.yield()
        events.append("startRelayDiscovery")
        return startDiscoverySnapshot
    }

    func stopRelayDiscovery() async -> TunnelDiscoverySnapshot {
        await Task.yield()
        events.append("stopRelayDiscovery")
        return startDiscoverySnapshot
    }

    func listRelayServices() async -> TunnelDiscoverySnapshot {
        await Task.yield()
        events.append("listRelayServices")
        return listedDiscoverySnapshot
    }

    func selectRelayService(serviceID: String) async -> TunnelDiscoverySnapshot {
        await Task.yield()
        events.append("selectRelayService")
        XCTAssertEqual(serviceID, "relay-1")
        return selectedDiscoverySnapshot
    }
}

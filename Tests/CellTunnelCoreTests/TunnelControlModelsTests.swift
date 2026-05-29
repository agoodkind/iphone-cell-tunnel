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

    func testCLIParseDevices() throws {
        let action = try TunnelControlCLIAction.parse(arguments: ["devices"])

        XCTAssertEqual(action, .devices)
    }

    func testCLIParseSelectRequiresReference() {
        XCTAssertThrowsError(try TunnelControlCLIAction.parse(arguments: ["select"]))
    }

    func testCLIParseSelectRejectsExtraArguments() {
        XCTAssertThrowsError(
            try TunnelControlCLIAction.parse(arguments: ["select", "relay-1", "extra"])
        )
    }

    func testCLIParseSelectTrimsAndStoresReference() throws {
        let action = try TunnelControlCLIAction.parse(arguments: ["select", "  relay-1  "])

        XCTAssertEqual(action, .select(reference: "relay-1"))
    }

    func testCLIExecutorDevicesListsNumberedServices() async throws {
        let client = FakeTunnelControlClient()
        let executor = TunnelControlCLIExecutor(client: client)

        let output = try await executor.run(action: .devices)

        XCTAssertEqual(client.events, ["listRelayServices"])
        XCTAssertEqual(output, "1) CellTunnelPhone  relay-1")
    }

    func testCLIExecutorDevicesReportsEmptyListing() async throws {
        let client = FakeTunnelControlClient()
        client.listedDiscoverySnapshotOverride = TunnelDiscoverySnapshot(
            phase: .browsing,
            services: []
        )
        let executor = TunnelControlCLIExecutor(client: client)

        let output = try await executor.run(action: .devices)

        XCTAssertEqual(output, "no relay devices found")
    }

    func testCLIExecutorSelectByServiceIDCallsSelectRelayService() async throws {
        let client = FakeTunnelControlClient()
        let executor = TunnelControlCLIExecutor(client: client)

        let output = try await executor.run(action: .select(reference: "relay-1"))

        XCTAssertEqual(client.events, ["selectRelayService"])
        XCTAssertEqual(output, client.selectedDiscoverySnapshot.renderedOutput)
    }

    func testCLIExecutorSelectByIndexResolvesServiceID() async throws {
        let client = FakeTunnelControlClient()
        let executor = TunnelControlCLIExecutor(client: client)

        let output = try await executor.run(action: .select(reference: "1"))

        XCTAssertEqual(client.events, ["listRelayServices", "selectRelayService"])
        XCTAssertEqual(output, client.selectedDiscoverySnapshot.renderedOutput)
    }

    func testCLIExecutorSelectByOutOfRangeIndexThrows() async {
        let client = FakeTunnelControlClient()
        let executor = TunnelControlCLIExecutor(client: client)

        let thrownError = await captureError {
            _ = try await executor.run(action: .select(reference: "9"))
        }

        guard let daemonError = thrownError as? TunnelDaemonError, case .usage = daemonError else {
            XCTFail("expected usage error, got \(String(describing: thrownError))")
            return
        }
        XCTAssertEqual(client.events, ["listRelayServices"])
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

// Runs a throwing operation and returns the thrown error so the caller can
// assert on it without a bare catch the swiftcheck-extra audit treats as silent.
private func captureError(
    during operation: () async throws -> Void
) async -> Error? {
    do {
        try await operation()
        return nil
    } catch {
        return error
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
    var listedDiscoverySnapshotOverride: TunnelDiscoverySnapshot?
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
        return listedDiscoverySnapshotOverride ?? listedDiscoverySnapshot
    }

    func selectRelayService(serviceID: String) async -> TunnelDiscoverySnapshot {
        await Task.yield()
        events.append("selectRelayService")
        XCTAssertEqual(serviceID, "relay-1")
        return selectedDiscoverySnapshot
    }
}

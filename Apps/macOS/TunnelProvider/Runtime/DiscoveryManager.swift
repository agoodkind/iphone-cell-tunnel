import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

let cellRelayBonjourServiceType = "_cellrelay._udp"
let cellRelayResolveTimeout: TimeInterval = 5.0

struct DiscoveredService: Codable, Hashable, Sendable {
    let identifier: String
    let serviceName: String
    let serviceType: String
    let domain: String
    let interfaceIndex: Int
    var resolvedEndpoint: TunnelRelayEndpoint?
}

enum DiscoveryResolveError: LocalizedError, Sendable {
    case cancelled
    case connectionFailed(String)
    case malformedEndpoint(String)
    case noBrowsedEndpoint(String)
    case timedOut
    case unknownService(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "relay endpoint resolution cancelled"
        case .connectionFailed(let detail):
            return "relay endpoint connection failed: \(detail)"
        case .malformedEndpoint(let detail):
            return "resolved endpoint is malformed: \(detail)"
        case .noBrowsedEndpoint(let id):
            return "no browsed NWEndpoint for service id=\(id)"
        case .timedOut:
            return "relay endpoint resolution timed out"
        case .unknownService(let id):
            return "unknown discovered service id=\(id)"
        }
    }
}

actor DiscoveryManager {
    private var browser: NWBrowser?
    private var services: Set<DiscoveredService> = []
    private var endpoints: [String: NWEndpoint] = [:]
    private var onServicesChanged: (@Sendable (Set<DiscoveredService>) -> Void)?
    private var resolveTask: Task<TunnelRelayEndpoint, Error>?
    private var resolveTaskServiceID: String?

    func start(onChange: (@Sendable (Set<DiscoveredService>) -> Void)? = nil) {
        if onChange != nil {
            onServicesChanged = onChange
        }
        guard browser == nil else {
            return
        }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: cellRelayBonjourServiceType,
            domain: nil
        )
        let nwBrowser = NWBrowser(for: descriptor, using: parameters)
        nwBrowser.stateUpdateHandler = { state in
            logger.notice(
                "discovery browser state=\(String(describing: state), privacy: .public)"
            )
        }
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { [weak self] in
                await self?.applyResults(results)
            }
        }
        nwBrowser.start(queue: .global(qos: .userInitiated))
        browser = nwBrowser
        logger.notice(
            "discovery browser started type=\(cellRelayBonjourServiceType, privacy: .public)"
        )
    }

    func stop() {
        cancelInFlightResolution(reason: "stop")
        guard let nwBrowser = browser else {
            services.removeAll()
            endpoints.removeAll()
            return
        }
        browser = nil
        nwBrowser.cancel()
        services.removeAll()
        endpoints.removeAll()
        onServicesChanged = nil
        logger.notice("discovery browser stopped")
    }

    func currentServices() -> [DiscoveredService] {
        Array(services)
    }

    func endpoint(forIdentifier identifier: String) -> NWEndpoint? {
        endpoints[identifier]
    }

    func resolve(_ serviceID: String) async throws -> TunnelRelayEndpoint {
        let existing = services.first { $0.identifier == serviceID }
        if let resolved = existing?.resolvedEndpoint {
            return resolved
        }
        cancelInFlightResolution(reason: "new-resolve")
        guard let endpoint = endpoints[serviceID] else {
            throw DiscoveryResolveError.noBrowsedEndpoint(serviceID)
        }
        let task = Task<TunnelRelayEndpoint, Error> {
            try await Self.performResolve(endpoint: endpoint)
        }
        resolveTask = task
        resolveTaskServiceID = serviceID
        defer {
            if resolveTaskServiceID == serviceID {
                resolveTask = nil
                resolveTaskServiceID = nil
            }
        }
        let resolved: TunnelRelayEndpoint
        do {
            resolved = try await task.value
        } catch is CancellationError {
            logger.notice(
                "discovery resolve cancelled service=\(serviceID, privacy: .public) recovery=throw-cancelled"
            )
            throw DiscoveryResolveError.cancelled
        }
        storeResolved(resolved, for: serviceID)
        return resolved
    }

    private func cancelInFlightResolution(reason: String) {
        guard let task = resolveTask else {
            return
        }
        let activeID = resolveTaskServiceID ?? ""
        task.cancel()
        resolveTask = nil
        resolveTaskServiceID = nil
        logger.notice(
            """
            discovery resolve cancelled reason=\(reason, privacy: .public) \
            serviceID=\(activeID, privacy: .public)
            """
        )
    }

    private func storeResolved(_ resolved: TunnelRelayEndpoint, for serviceID: String) {
        guard var entry = services.first(where: { $0.identifier == serviceID }) else {
            return
        }
        services.remove(entry)
        entry.resolvedEndpoint = resolved
        services.insert(entry)
        onServicesChanged?(services)
    }

    private func applyResults(_ results: Set<NWBrowser.Result>) {
        var next: Set<DiscoveredService> = []
        var nextEndpoints: [String: NWEndpoint] = [:]
        for result in results {
            guard let entry = service(from: result) else {
                continue
            }
            var carried = entry.service
            if let existing = services.first(where: { $0.identifier == carried.identifier }) {
                carried.resolvedEndpoint = existing.resolvedEndpoint
            }
            next.insert(carried)
            nextEndpoints[carried.identifier] = entry.endpoint
        }
        let added = next.subtracting(services)
        let removed = services.subtracting(next)
        services = next
        endpoints = nextEndpoints
        if !added.isEmpty || !removed.isEmpty {
            logger.notice(
                """
                discovery services updated added=\(added.count, privacy: .public) \
                removed=\(removed.count, privacy: .public) total=\(next.count, privacy: .public)
                """
            )
            onServicesChanged?(next)
        }
    }

    private func service(
        from result: NWBrowser.Result
    ) -> (service: DiscoveredService, endpoint: NWEndpoint)? {
        guard case .service(let name, let type, let domain, let interface) = result.endpoint else {
            return nil
        }
        let interfaceIndex = interface.map { Int($0.index) } ?? 0
        let identifier = "\(name).\(type).\(domain)#\(interfaceIndex)"
        let entry = DiscoveredService(
            identifier: identifier,
            serviceName: name,
            serviceType: type,
            domain: domain,
            interfaceIndex: interfaceIndex,
            resolvedEndpoint: nil
        )
        return (entry, result.endpoint)
    }

    private static func performResolve(
        endpoint: NWEndpoint
    ) async throws -> TunnelRelayEndpoint {
        logger.notice(
            "discovery resolve dialing endpoint=\(String(describing: endpoint), privacy: .public)"
        )
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        let resolver = Resolver(connection: connection)
        return try await resolver.run(timeout: cellRelayResolveTimeout)
    }
}

private final class Resolver: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<TunnelRelayEndpoint, Error>?
    private var timeoutItem: DispatchWorkItem?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func run(timeout: TimeInterval) async throws -> TunnelRelayEndpoint {
        try await runResolverContinuation(timeout: timeout)
    }

    private func runResolverContinuation(
        timeout: TimeInterval
    ) async throws -> TunnelRelayEndpoint {
        logger.notice(
            "discovery resolver continuation starting timeout=\(timeout, privacy: .public)"
        )
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }
            connection.pathUpdateHandler = { [weak self] path in
                self?.tryFinish(usingPath: path)
            }
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.finish(.failure(DiscoveryResolveError.timedOut))
            }
            self.timeoutItem = timeoutItem
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutItem
            )
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready, .preparing:
            tryFinish(usingPath: connection.currentPath)
        case .failed(let error):
            finish(.failure(DiscoveryResolveError.connectionFailed(String(describing: error))))
        case .cancelled:
            finish(.failure(DiscoveryResolveError.cancelled))
        case .waiting(let error):
            finish(.failure(DiscoveryResolveError.connectionFailed(String(describing: error))))
        default:
            break
        }
    }

    private func tryFinish(usingPath path: NWPath?) {
        guard let path else {
            return
        }
        guard let remote = path.remoteEndpoint else {
            return
        }
        guard let endpoint = Self.endpoint(from: remote) else {
            return
        }
        finish(.success(endpoint))
    }

    private func finish(_ result: Result<TunnelRelayEndpoint, Error>) {
        logger.notice(
            "discovery resolver finish requested outcome=\(String(describing: result), privacy: .public)"
        )
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let timer = timeoutItem
        timeoutItem = nil
        lock.unlock()

        timer?.cancel()
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
        cont?.resume(with: result)
    }

    private static func endpoint(from endpoint: NWEndpoint) -> TunnelRelayEndpoint? {
        guard let components = hostPortComponents(endpoint) else {
            return nil
        }
        return relayEndpoint(host: components.host, port: components.port)
    }

    private static func hostPortComponents(
        _ endpoint: NWEndpoint
    ) -> (host: NWEndpoint.Host, port: NWEndpoint.Port)? {
        guard case .hostPort(let host, let port) = endpoint else {
            return nil
        }
        return (host, port)
    }

    private static func relayEndpoint(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port
    ) -> TunnelRelayEndpoint? {
        switch host {
        case .ipv4(let address):
            let literal = stringAddress(address)
            return TunnelRelayEndpoint(
                host: literal,
                port: Int(port.rawValue),
                addressFamily: .ipv4
            )
        case .ipv6(let address):
            let literal = scopedAddress(address)
            return TunnelRelayEndpoint(
                host: literal,
                port: Int(port.rawValue),
                addressFamily: .ipv6
            )
        case .name(let name, _):
            return TunnelRelayEndpoint(
                host: name,
                port: Int(port.rawValue),
                addressFamily: .unspecified
            )
        @unknown default:
            return nil
        }
    }

    private static func stringAddress(_ address: IPv4Address) -> String {
        let raw = address.debugDescription
        if let percentIndex = raw.firstIndex(of: "%") {
            return String(raw[..<percentIndex])
        }
        return raw
    }

    // The iPhone relay advertises a link-local address (fe80::/10), which only
    // routes when qualified with the interface scope it lives on. Keep the zone
    // from the address, and fall back to the resolved interface name, so the
    // reconstructed NWEndpoint can reach the relay over USB/AWDL.
    private static func scopedAddress(_ address: IPv6Address) -> String {
        let raw = address.debugDescription
        if raw.contains("%") {
            return raw
        }
        if let interfaceName = address.interface?.name {
            return "\(raw)%\(interfaceName)"
        }
        return raw
    }
}

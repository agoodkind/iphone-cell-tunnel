import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

let cellRelayBonjourServiceType = "_cellrelay._udp"

struct DiscoveredService: Codable, Hashable, Sendable {
    let identifier: String
    let serviceName: String
    let serviceType: String
    let domain: String
    let interfaceIndex: Int
}

actor DiscoveryManager {
    private var browser: NWBrowser?
    private var services: Set<DiscoveredService> = []
    private var endpoints: [String: NWEndpoint] = [:]
    var onServicesChanged: ((Set<DiscoveredService>) -> Void)?

    func start() {
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
        guard let nwBrowser = browser else {
            return
        }
        browser = nil
        nwBrowser.cancel()
        services.removeAll()
        endpoints.removeAll()
        logger.notice("discovery browser stopped")
    }

    func currentServices() -> [DiscoveredService] {
        Array(services)
    }

    func endpoint(forIdentifier identifier: String) -> NWEndpoint? {
        endpoints[identifier]
    }

    private func applyResults(_ results: Set<NWBrowser.Result>) {
        var next: Set<DiscoveredService> = []
        var nextEndpoints: [String: NWEndpoint] = [:]
        for result in results {
            guard let entry = service(from: result) else {
                continue
            }
            next.insert(entry.service)
            nextEndpoints[entry.service.identifier] = entry.endpoint
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

    private func service(from result: NWBrowser.Result) -> (service: DiscoveredService, endpoint: NWEndpoint)? {
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
            interfaceIndex: interfaceIndex
        )
        return (entry, result.endpoint)
    }
}

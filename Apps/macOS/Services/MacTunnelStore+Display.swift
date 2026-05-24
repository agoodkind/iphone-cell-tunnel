extension MacTunnelStore {
    var counterDescription: String {
        """
        wgToServer=\(counters.wireGuardDatagramsToServer) \
        wgToMac=\(counters.wireGuardDatagramsToMac) \
        dropped=\(counters.droppedWireGuardDatagrams)
        """
    }

    var tunnelStateDescription: String {
        tunnelState.displayName
    }

    var routeStateDescription: String {
        routeState.displayName
    }

    var helperStateDescription: String {
        helperState.displayName
    }

    var wireGuardConfigDescription: String {
        guard !wireGuardConfigPath.isEmpty else {
            return "Not selected"
        }
        return wireGuardConfigPath
    }

    var relayEndpointDescription: String {
        if let selectedRelayService = discoveredRelayServices.first(where: { service in
            service.id == selectedRelayServiceID
        }) {
            return selectedRelayService.displayName
        }
        return "Not selected"
    }

    var relayDiscoveryStateDescription: String {
        relayDiscoveryState.displayName
    }
}

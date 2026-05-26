extension PhoneRelayController {
    var serviceDescription: String {
        guard isAdvertising else {
            return "Inactive"
        }
        let serviceName = advertisedServiceName ?? "Unknown"
        if let listenerPort {
            return "\(serviceName) _cellrelay._udp \(listenerPort)"
        }
        return "\(serviceName) _cellrelay._udp"
    }

    var serviceNameDescription: String {
        advertisedServiceName ?? "Not advertised"
    }

    var listenerPortDescription: String {
        if let listenerPort {
            return listenerPort.formatted()
        }
        return "Unknown"
    }

    var cellularInterfaceDescription: String {
        guard let interfaceName = cellularPath.interfaceName else {
            return "Unknown"
        }

        if let interfaceIndex = cellularPath.interfaceIndex {
            return "\(interfaceName) (\(interfaceIndex))"
        }

        return interfaceName
    }
}

extension PhoneRelayController {
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

import Foundation

public let helperMachServiceName = "io.goodkind.celltunneldhelperd.xpc"
public let helperWireVersion: Int = 1

public enum HelperRPC: String, Codable, Sendable {
    case openUtunDevice = "open-utun-device"
    case installRoutes = "install-routes"
    case removeRoutes = "remove-routes"
}

public enum HelperAddressFamily: String, Codable, Sendable {
    case ipv4
    case ipv6
}

public struct HelperAddressPrefix: Codable, Equatable, Sendable {
    public var family: HelperAddressFamily
    public var address: String
    public var prefixLength: Int

    public init(family: HelperAddressFamily, address: String, prefixLength: Int) {
        self.family = family
        self.address = address
        self.prefixLength = prefixLength
    }
}

public struct HelperOpenUtunRequest: Codable, Sendable {
    public init() {
        // no payload
    }
}

public struct HelperOpenUtunResponse: Codable, Sendable {
    public var interfaceName: String

    public init(interfaceName: String) {
        self.interfaceName = interfaceName
    }
}

public struct HelperInstallRoutesRequest: Codable, Sendable {
    public var interfaceName: String
    public var prefixes: [HelperAddressPrefix]

    public init(interfaceName: String, prefixes: [HelperAddressPrefix]) {
        self.interfaceName = interfaceName
        self.prefixes = prefixes
    }
}

public struct HelperInstallRoutesResponse: Codable, Sendable {
    public init() {
        // no payload
    }
}

public struct HelperRemoveRoutesRequest: Codable, Sendable {
    public init() {
        // no payload
    }
}

public struct HelperRemoveRoutesResponse: Codable, Sendable {
    public init() {
        // no payload
    }
}

public struct HelperFailure: Codable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum HelperPayload: Sendable {
    case openUtunRequest(HelperOpenUtunRequest)
    case openUtunResponse(HelperOpenUtunResponse)
    case installRoutesRequest(HelperInstallRoutesRequest)
    case installRoutesResponse(HelperInstallRoutesResponse)
    case removeRoutesRequest(HelperRemoveRoutesRequest)
    case removeRoutesResponse(HelperRemoveRoutesResponse)
}

public struct HelperRequestEnvelope: Codable, Sendable {
    public var version: Int
    public var rpc: HelperRPC
    public var openUtun: HelperOpenUtunRequest?
    public var installRoutes: HelperInstallRoutesRequest?
    public var removeRoutes: HelperRemoveRoutesRequest?

    public init(
        rpc: HelperRPC,
        openUtun: HelperOpenUtunRequest? = nil,
        installRoutes: HelperInstallRoutesRequest? = nil,
        removeRoutes: HelperRemoveRoutesRequest? = nil,
        version: Int = helperWireVersion
    ) {
        self.version = version
        self.rpc = rpc
        self.openUtun = openUtun
        self.installRoutes = installRoutes
        self.removeRoutes = removeRoutes
    }
}

public struct HelperResponseEnvelope: Codable, Sendable {
    public var version: Int
    public var openUtun: HelperOpenUtunResponse?
    public var installRoutes: HelperInstallRoutesResponse?
    public var removeRoutes: HelperRemoveRoutesResponse?
    public var failure: HelperFailure?

    public init(
        openUtun: HelperOpenUtunResponse? = nil,
        installRoutes: HelperInstallRoutesResponse? = nil,
        removeRoutes: HelperRemoveRoutesResponse? = nil,
        failure: HelperFailure? = nil,
        version: Int = helperWireVersion
    ) {
        self.version = version
        self.openUtun = openUtun
        self.installRoutes = installRoutes
        self.removeRoutes = removeRoutes
        self.failure = failure
    }
}

public let helperXPCRequestJSONKey = "request-json"
public let helperXPCResponseJSONKey = "response-json"
public let helperXPCUtunFileDescriptorKey = "utun-fd"

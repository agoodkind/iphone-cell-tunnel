import CellTunnelCore
import CellTunnelLog
import Darwin
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

@objc(CellTunnelHelperProtocol)
public protocol CellTunnelHelperProtocol {
    func openUtunDevice(
        requestData: Data,
        reply: @escaping (Data?, FileHandle?, NSError?) -> Void
    )
    func installRoutes(requestData: Data, reply: @escaping (Data?, NSError?) -> Void)
    func removeRoutes(requestData: Data, reply: @escaping (Data?, NSError?) -> Void)
}

let helperErrorDomain = "io.goodkind.celltunneldhelperd"

final class HelperState: @unchecked Sendable {
    private let lock = NSLock()
    private var routeManager: RouteManager?
    private var openedUtuns: [UtunDevice] = []

    func registerUtun(_ device: UtunDevice) {
        lock.lock()
        defer { lock.unlock() }
        openedUtuns.append(device)
    }

    func currentRouteManager() -> RouteManager {
        lock.lock()
        defer { lock.unlock() }
        if let manager = routeManager {
            return manager
        }
        let manager = RouteManager()
        routeManager = manager
        return manager
    }

    func clearRouteManager() {
        lock.lock()
        defer { lock.unlock() }
        routeManager = nil
    }

    func shutdown() {
        lock.lock()
        let managerSnapshot = routeManager
        let utunSnapshot = openedUtuns
        routeManager = nil
        openedUtuns = []
        lock.unlock()

        if let manager = managerSnapshot {
            do {
                try manager.removeAll()
            } catch {
                logger.error(
                    "helper shutdown route remove failed error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        for device in utunSnapshot {
            device.close()
        }
    }
}

final class HelperControlServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let state: HelperState
    private let listener: NSXPCListener

    init(state: HelperState) {
        self.state = state
        self.listener = NSXPCListener(machServiceName: helperMachServiceName)
        super.init()
    }

    func start() {
        listener.delegate = self
        listener.resume()
        logger.notice(
            "helper control server started service=\(helperMachServiceName, privacy: .public)"
        )
    }

    func stop() {
        listener.suspend()
        logger.notice("helper control server stopped")
    }

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let interface = NSXPCInterface(with: CellTunnelHelperProtocol.self)
        newConnection.exportedInterface = interface
        let exportedObject = HelperRPCExport(state: state)
        newConnection.exportedObject = exportedObject
        newConnection.invalidationHandler = {
            logger.notice("helper xpc connection invalidated")
        }
        newConnection.interruptionHandler = {
            logger.notice("helper xpc connection interrupted")
        }
        newConnection.resume()
        logger.notice("helper xpc connection accepted")
        return true
    }
}

private final class HelperRPCExport: NSObject, CellTunnelHelperProtocol {
    private let state: HelperState

    init(state: HelperState) {
        self.state = state
        super.init()
    }

    func openUtunDevice(
        requestData: Data,
        reply: @escaping (Data?, FileHandle?, NSError?) -> Void
    ) {
        do {
            let envelope = try decodeRequest(requestData, expecting: .openUtunDevice)
            guard envelope.openUtun != nil else {
                throw helperError(code: "missing-payload", message: "missing open-utun payload")
            }
            let device = try UtunDevice()
            state.registerUtun(device)
            let handle = FileHandle(fileDescriptor: device.fileDescriptor, closeOnDealloc: false)
            let response = HelperResponseEnvelope(
                openUtun: HelperOpenUtunResponse(interfaceName: device.interfaceName)
            )
            let responseData = try JSONEncoder().encode(response)
            logger.notice(
                """
                helper open-utun completed interface=\
                \(device.interfaceName, privacy: .public) \
                fd=\(device.fileDescriptor, privacy: .public)
                """
            )
            reply(responseData, handle, nil)
        } catch {
            replyWithFailure(error: error) { data, nsError in
                reply(data, nil, nsError)
            }
        }
    }

    func installRoutes(requestData: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let envelope = try decodeRequest(requestData, expecting: .installRoutes)
            guard let payload = envelope.installRoutes else {
                throw helperError(code: "missing-payload", message: "missing install-routes payload")
            }
            let manager = state.currentRouteManager()
            let prefixes = payload.prefixes.map { prefix -> AddressPrefix in
                let family: AddressFamily = prefix.family == .ipv4 ? .ipv4 : .ipv6
                return AddressPrefix(
                    family: family,
                    address: prefix.address,
                    prefixLength: prefix.prefixLength
                )
            }
            try manager.install(prefixes: prefixes, onInterface: payload.interfaceName)
            let response = HelperResponseEnvelope(installRoutes: HelperInstallRoutesResponse())
            let responseData = try JSONEncoder().encode(response)
            logger.notice(
                """
                helper install-routes completed interface=\
                \(payload.interfaceName, privacy: .public) \
                count=\(payload.prefixes.count, privacy: .public)
                """
            )
            reply(responseData, nil)
        } catch {
            replyWithFailure(error: error, completion: reply)
        }
    }

    func removeRoutes(requestData: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            _ = try decodeRequest(requestData, expecting: .removeRoutes)
            let manager = state.currentRouteManager()
            try manager.removeAll()
            state.clearRouteManager()
            let response = HelperResponseEnvelope(removeRoutes: HelperRemoveRoutesResponse())
            let responseData = try JSONEncoder().encode(response)
            logger.notice("helper remove-routes completed")
            reply(responseData, nil)
        } catch {
            replyWithFailure(error: error, completion: reply)
        }
    }

    private func decodeRequest(
        _ data: Data,
        expecting rpc: HelperRPC
    ) throws -> HelperRequestEnvelope {
        let envelope = try JSONDecoder().decode(HelperRequestEnvelope.self, from: data)
        guard envelope.version == helperWireVersion else {
            throw helperError(
                code: "unsupported-version",
                message: "unsupported helper request version \(envelope.version)"
            )
        }
        guard envelope.rpc == rpc else {
            throw helperError(
                code: "rpc-mismatch",
                message: "expected \(rpc.rawValue) but got \(envelope.rpc.rawValue)"
            )
        }
        return envelope
    }

    private func replyWithFailure(error: Error, completion: (Data?, NSError?) -> Void) {
        let nsError = error as NSError
        logger.error(
            "helper rpc failed details=\(String(describing: error), privacy: .public)"
        )
        let failure = HelperFailure(
            code: nsError.domain == helperErrorDomain
                ? (nsError.userInfo["code"] as? String ?? "failure")
                : "exception",
            message: nsError.localizedDescription
        )
        let envelope = HelperResponseEnvelope(failure: failure)
        let responseData = try? JSONEncoder().encode(envelope)
        completion(responseData, nsError)
    }

    private func helperError(code: String, message: String) -> NSError {
        NSError(
            domain: helperErrorDomain,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                "code": code,
            ]
        )
    }
}

import Foundation

/// NSXPC protocol exposed by celltunneld over the Mach service named
/// `daemonControlMachServiceName`. The wire payload is a JSON-encoded
/// `DaemonControlRequest`/`DaemonControlResponse` pair so this protocol
/// stays primitive-only (compatible with NSXPCCoder) and matches the
/// helper transport already in use elsewhere in the codebase.
@objc(CellTunnelDaemonControlProtocol)
public protocol CellTunnelDaemonControlProtocol {
    func handleControlRequest(
        requestData: Data,
        reply: @escaping (Data?, NSError?) -> Void
    )
}

public let daemonControlErrorDomain = "io.goodkind.celltunneld.control"

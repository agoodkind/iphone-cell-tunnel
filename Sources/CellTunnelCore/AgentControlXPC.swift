import Foundation

// The string constants used by the XPC layer (mach service name, agent
// bundle id, tunnel provider bundle id, launchd plist name, etc.) are
// generated into Config.generated.swift by `swift-mk render-batch` from
// Config/Constants.xcconfig. See xcconfig.mk + Makefile for the pipeline.

@objc(CellTunnelAgentControlXPC)
public protocol AgentControlXPC {
    func sendRequest(_ payload: Data, withReply reply: @escaping (Data?) -> Void)
}

// The libxpc dictionary key carrying the JSON-encoded request and response
// between the Mac Catalyst app and the agent's modern libxpc listener. The
// Catalyst app cannot open an NSXPCConnection to a mach service, so it dials the
// agent's session mach service with the libxpc session API and exchanges the same
// AgentControlEnvelope / AgentControlResponse JSON under this key. Both ends pass
// it to the C xpc dictionary calls, which require a C string.
public let agentSessionPayloadKey = "payload"

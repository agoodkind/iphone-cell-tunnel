import Foundation

// The string constants used by the XPC layer (mach service name, agent
// bundle id, tunnel provider bundle id, launchd plist name, etc.) are
// generated into Config.generated.swift by `swift-mk render-batch` from
// Config/Constants.xcconfig. See xcconfig.mk + Makefile for the pipeline.

@objc(CellTunnelAgentControlXPC)
public protocol AgentControlXPC {
    func sendRequest(_ payload: Data, withReply reply: @escaping (Data?) -> Void)
}

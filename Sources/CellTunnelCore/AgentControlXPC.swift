import Foundation

public let agentMachServiceName = "io.goodkind.celltunnel-agent"
public let agentLaunchAgentPlistName = "io.goodkind.celltunnel-agent.plist"
public let agentBinaryName = "CellTunnelAgent"
public let agentAppBundleName = "CellTunnelAgent.app"
public let agentBundleIdentifier = "io.goodkind.CellTunnel.Agent"
public let tunnelProviderBundleIdentifier = "io.goodkind.CellTunnel.Agent.TunnelProvider"

@objc(CellTunnelAgentControlXPC)
public protocol AgentControlXPC {
    func sendRequest(_ payload: Data, withReply reply: @escaping (Data?) -> Void)
}

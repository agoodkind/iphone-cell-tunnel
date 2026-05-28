import Foundation

public let agentControlEndpointPath = "/tmp/io.goodkind.celltunnel-agent.sock"
public let agentBinaryEnvironmentVariable = "CELL_TUNNEL_AGENT_BINARY"
public let agentBinaryName = "CellTunnelAgent"
public let agentAppBundleName = "CellTunnelAgent.app"
public let agentBundleIdentifier = "io.goodkind.CellTunnel.Agent"
public let tunnelProviderBundleIdentifier = "io.goodkind.CellTunnel.Agent.TunnelProvider"

@objc(CellTunnelAgentControlXPC)
public protocol AgentControlXPC {
    func sendRequest(_ payload: Data, withReply reply: @escaping (Data?) -> Void)
}

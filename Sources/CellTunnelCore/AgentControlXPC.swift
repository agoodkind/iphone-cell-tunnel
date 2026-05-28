import Foundation

public let agentControlEndpointPath = "/tmp/io.goodkind.celltunnel-agent.sock"
public let agentBinaryEnvironmentVariable = "CELL_TUNNEL_AGENT_BINARY"
public let agentBinaryName = "CellTunnelAgent"

@objc(CellTunnelAgentControlXPC)
public protocol AgentControlXPC {
    func sendRequest(_ payload: Data, withReply reply: @escaping (Data?) -> Void)
}

//
//  AgentControlXPC.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// The string constants used by the XPC layer (mach service name, agent
// bundle id, tunnel provider bundle id, launchd plist name, etc.) are
// generated into Config.generated.swift by `swift-mk render-batch` from
// Config/Constants.xcconfig. See xcconfig.mk + Makefile for the pipeline.

// The libxpc dictionary key carrying the JSON-encoded request and response
// between a control client and the agent's libxpc listener. Both ends exchange
// the same AgentControlEnvelope / AgentControlResponse JSON under this key, and
// both pass it to the C xpc dictionary calls, which require a C string.
public let agentControlPayloadKey = "payload"

//
//  ActivationTarget.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

enum ActivationTarget: String, CaseIterable {
  case iphone
  case iphoneSimulator = "iphone-simulator"
  case macCatalyst = "mac-catalyst"
}

// MARK: - XcodeBuildCacheMode

enum XcodeBuildCacheMode {
  case disabled
  case enabled
}

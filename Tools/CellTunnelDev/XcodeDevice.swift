//
//  XcodeDevice.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation

struct XcodeDevice: Decodable {
  let simulator: Bool
  let available: Bool
  let platform: String
  let identifier: String
  let name: String
}

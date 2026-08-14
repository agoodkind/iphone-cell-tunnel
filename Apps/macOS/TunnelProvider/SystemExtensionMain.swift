//
//  SystemExtensionMain.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-13.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import NetworkExtension

// The download signs Developer ID, which permits the tunnel entitlement only in
// its system-extension form, so that build compiles these same provider sources
// into a system extension instead of an app extension. An app extension is
// started for us through NSExtensionMain; a system extension is an ordinary
// executable that registers its provider itself and then waits.
//
// The entry point is compiled only in that build, and the file stays in the
// target's sources either way so every owned source keeps its dead-code
// coverage.
#if CELL_TUNNEL_SYSTEM_EXTENSION

  @main
  enum SystemExtensionMain {
    static func main() {
      autoreleasepool {
        NEProvider.startSystemExtensionMode()
      }
      dispatchMain()
    }
  }

#endif

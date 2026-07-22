//
//  PhoneTunnelProvisioningBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-21.
//  Copyright © 2026, all rights reserved.
//

#if !targetEnvironment(macCatalyst)
  // MARK: - PhoneTunnelProvisioningBackend

  /// The iPhone-only read of its one-time VPN approval state. It does not expose
  /// library operations or configuration mutation.
  @MainActor
  protocol PhoneTunnelProvisioningBackend {
    /// Returns true when the iPhone's own VPN configuration is already approved.
    func tunnelProvisioned() async -> Bool
  }
#endif

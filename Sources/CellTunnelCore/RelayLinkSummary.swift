//
//  RelayLinkSummary.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - RelayLinkSummary

/// One relay-link candidate as the status surface and the control wire carry
/// it: the interface identifier and its transport class, nothing else. The
/// scored candidate types stay process local; this summary freezes only the
/// stable facts so the wire format never leaks scoring policy.
public struct RelayLinkSummary: Codable, Equatable, Hashable, Sendable {
  /// The raw interface identifier, such as `en0` or `awdl0`.
  public let interfaceName: String
  /// The transport class of the interface, the source of the displayed word.
  public let linkClass: RelayLinkClass

  /// Creates one summary from the stable link facts.
  public init(interfaceName: String, linkClass: RelayLinkClass) {
    self.interfaceName = interfaceName
    self.linkClass = linkClass
  }

  /// Sorts summaries best first through the shared scorer with no path
  /// penalties, ties broken by interface name, so both peers and both
  /// screens render the same stable order.
  public static func preferenceSorted(_ links: [Self]) -> [Self] {
    links.sorted { lhs, rhs in
      let leftScore = RelayLinkScorer.score(
        linkClass: lhs.linkClass,
        isExpensive: false,
        isConstrained: false
      )
      let rightScore = RelayLinkScorer.score(
        linkClass: rhs.linkClass,
        isExpensive: false,
        isConstrained: false
      )
      if leftScore != rightScore {
        return leftScore > rightScore
      }
      return lhs.interfaceName < rhs.interfaceName
    }
  }
}

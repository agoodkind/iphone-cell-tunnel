//
//  RelayPathEvaluation.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - RelayLinkClass

/// The class of physical link a relay candidate path runs over, ranked for
/// throughput. A probe maps each available interface to one of these and the
/// scorer ranks them. Wired and Wi-Fi LAN are the high throughput paths. The
/// Apple peer-to-peer link (AWDL) is the low throughput fallback because it
/// duty-cycles its radio in availability windows. Cellular, loopback, and other
/// cannot carry the Mac-to-iPhone link and exist only so the interface mapping
/// is total.
public enum RelayLinkClass: String, Codable, Sendable, Equatable, CaseIterable {
  case cellular
  case loopback
  case other
  case peerToPeer = "peer-to-peer"
  case wifiLan = "wifi-lan"
  case wired

  /// Whether this class can carry the Mac-to-iPhone relay link. The probe emits
  /// only candidates that pass this filter, so the manager never dials a path
  /// that cannot reach the Mac agent over the local link.
  public var isMacLinkCapable: Bool {
    switch self {
    case .wired, .wifiLan, .peerToPeer:
      true
    case .cellular, .loopback, .other:
      false
    }
  }

  /// The transport name shown on the status screen, the one place a class maps to
  /// a user-facing word. The `Connected via` row renders this for the carrying
  /// link's class.
  public var displayName: String {
    switch self {
    case .wired:
      "Wired"
    case .wifiLan:
      "Wi-Fi"
    case .peerToPeer:
      "Peer-to-Peer"
    case .cellular:
      "Cellular"
    case .loopback:
      "Loopback"
    case .other:
      "Other"
    }
  }
}

// MARK: - RelayLinkScorer

/// Ranks a candidate link from its class and the path flags. Higher is better.
/// The ranking is the whole policy: wired beats Wi-Fi LAN beats peer-to-peer,
/// and an expensive or constrained path is penalized. The score is passive, so
/// it needs no test traffic; an active throughput prober can replace this scorer
/// later without changing the evaluation type or the manager that consumes it.
public enum RelayLinkScorer {
  // MARK: - Score constants

  private static let wiredScore = 100
  private static let wifiLanScore = 80
  private static let peerToPeerScore = 30
  private static let cellularScore = 10
  private static let loopbackScore = 5
  private static let otherScore = 1
  private static let expensivePenalty = 20
  private static let constrainedPenalty = 20

  // MARK: - Scoring

  /// Returns the score for a link class with the given path flags. Pure: the
  /// same inputs always produce the same score.
  public static func score(
    linkClass: RelayLinkClass,
    isExpensive: Bool,
    isConstrained: Bool
  ) -> Int {
    var value = baseScore(for: linkClass)
    if isExpensive {
      value -= expensivePenalty
    }
    if isConstrained {
      value -= constrainedPenalty
    }
    return value
  }

  private static func baseScore(for linkClass: RelayLinkClass) -> Int {
    switch linkClass {
    case .wired:
      wiredScore
    case .wifiLan:
      wifiLanScore
    case .peerToPeer:
      peerToPeerScore
    case .cellular:
      cellularScore
    case .loopback:
      loopbackScore
    case .other:
      otherScore
    }
  }
}

// MARK: - RelayLinkCandidate

/// One scored candidate path the probe found on an interface change. The score
/// is computed once at construction from the class and flags so the manager can
/// compare candidates by a single number.
public struct RelayLinkCandidate: Sendable, Equatable {
  public let interfaceName: String
  public let linkClass: RelayLinkClass
  public let isExpensive: Bool
  public let isConstrained: Bool
  public let score: Int

  public init(
    interfaceName: String,
    linkClass: RelayLinkClass,
    isExpensive: Bool,
    isConstrained: Bool
  ) {
    self.interfaceName = interfaceName
    self.linkClass = linkClass
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
    self.score = RelayLinkScorer.score(
      linkClass: linkClass,
      isExpensive: isExpensive,
      isConstrained: isConstrained
    )
  }
}

// MARK: - RelayPathEvaluation

/// The probe's only output: the candidate links found on the latest interface
/// change, sorted best first. The manager reads `best` to decide whether to
/// switch and walks `candidates` in order when it must establish a fresh link.
public struct RelayPathEvaluation: Sendable, Equatable {
  public let candidates: [RelayLinkCandidate]

  /// The highest scored candidate, or nil when no link-capable path is present.
  public var best: RelayLinkCandidate? {
    candidates.first
  }

  /// Sorts the candidates best first, breaking score ties by interface name so
  /// the order is stable across evaluations.
  public init(candidates: [RelayLinkCandidate]) {
    self.candidates = candidates.sorted { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      return lhs.interfaceName < rhs.interfaceName
    }
  }
}

// MARK: - RelayLinkSnapshot

/// One open link as the carrying chooser sees it: the interface it runs over and
/// its scored preference. The relay builds one per open link off the packet path.
/// It carries no Network object so the chooser stays pure and testable.
public struct RelayLinkSnapshot: Sendable, Equatable {
  public let interfaceName: String
  public let linkClass: RelayLinkClass
  public let score: Int

  public init(interfaceName: String, linkClass: RelayLinkClass) {
    self.interfaceName = interfaceName
    self.linkClass = linkClass
    self.score = RelayLinkScorer.score(
      linkClass: linkClass, isExpensive: false, isConstrained: false
    )
  }
}

// MARK: - RelayLinkPolicy

/// Chooses which open link carries traffic. This is the one seam a UI or a future
/// selection algorithm drives: pass an override to force a link, or pass nil to
/// take the highest-scoring open link. The scores (`RelayLinkScorer`) are the only
/// place the preference order lives, so reordering is one edit there. Pure: the
/// same inputs always produce the same choice, recomputed off the packet path only
/// when a link opens or closes.
public enum RelayLinkPolicy {
  /// Returns the interface to carry on. If `preferred` names an open link, it
  /// wins. Otherwise the highest-scoring open link wins, ties broken by interface
  /// name so both ends choose the same one. Returns nil when no link is open.
  public static func chooseCarrying(
    preferred: String?, openLinks: [RelayLinkSnapshot]
  ) -> String? {
    if let preferred, openLinks.contains(where: { $0.interfaceName == preferred }) {
      return preferred
    }
    let ranked = openLinks.sorted { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      return lhs.interfaceName < rhs.interfaceName
    }
    return ranked.first?.interfaceName
  }
}

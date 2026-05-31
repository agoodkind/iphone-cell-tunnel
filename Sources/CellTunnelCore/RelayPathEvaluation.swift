//
//  RelayPathEvaluation.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
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
public enum RelayLinkClass: String, Sendable, CaseIterable {
    case cellular
    case loopback
    case other
    case peerToPeer
    case wifiLan
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

// MARK: - RelayTransportPolicy

/// The declared inputs the carrying-link algorithm reads. They are knobs, not
/// thresholds that close links: the policy in force, the cadence of the keepalive
/// the relay sends on every warm link, and the flap margin that keeps two links a
/// hair apart from trading places. None of them ever closes a link; a link closes
/// only when its connection errors.
public enum RelayTransportPolicy {
    /// The policy the relay runs. Changing behavior is this one value or a new
    /// case in `RelayLinkPolicyKind`.
    public static let activeLinkPolicy = RelayLinkPolicyKind.activeBackup

    /// How often each side sends an empty keepalive on every warm link. The relay
    /// forwards only non-empty datagrams, so a keepalive never reaches WireGuard;
    /// it exists only to refresh the receiving side's freshness.
    public static let heartbeatIntervalMilliseconds = 250

    /// The floor on the relative freshness band. Two links whose last packet
    /// arrived within this of each other are treated as equally fresh, so links a
    /// cadence apart do not trade the carrying role. The band grows above this
    /// floor with the freshest link's own silence, so the comparison stays
    /// relative when every link is slow. This never closes a link.
    public static let flapMarginFloorMilliseconds = 1_000
}

// MARK: - RelayLinkSnapshot

/// One open link as the policy sees it: which interface it runs over, its scored
/// preference, and its freshness, the time since a packet last arrived on it. The
/// relay builds one per open link off the packet path and hands the set to the
/// policy whenever the set or its freshness changes. It carries no Network object
/// so the policy stays pure and testable.
public struct RelayLinkSnapshot: Sendable, Equatable {
    public let interfaceName: String
    public let linkClass: RelayLinkClass
    public let score: Int
    public let silenceMilliseconds: Int

    public init(
        interfaceName: String, linkClass: RelayLinkClass, silenceMilliseconds: Int
    ) {
        self.interfaceName = interfaceName
        self.linkClass = linkClass
        self.score = RelayLinkScorer.score(
            linkClass: linkClass, isExpensive: false, isConstrained: false
        )
        self.silenceMilliseconds = silenceMilliseconds
    }
}

// MARK: - RelayLinkPlan

/// What the policy decided. `keepWarm` lists the interfaces to dial and hold open,
/// best first. `egressOrder` ranks the same links for carrying traffic, the links
/// keeping up first in declared preference order, then any lagging links. The hot
/// path carries on `egressInterfaceName`, recomputed off the packet path. The
/// order is never empty while any link is open, so the carrying link never
/// vanishes during a blackout.
public struct RelayLinkPlan: Sendable, Equatable {
    public let keepWarm: [String]
    public let egressOrder: [String]

    public init(keepWarm: [String], egressOrder: [String]) {
        self.keepWarm = keepWarm
        self.egressOrder = egressOrder
    }

    /// The interface the hot path carries traffic on, or nil when no link is open.
    public var egressInterfaceName: String? {
        egressOrder.first
    }
}

// MARK: - RelayLinkPolicyKind

/// The policies the relay can run. Each is a declared input to the same
/// algorithm, swapped through `RelayTransportPolicy.activeLinkPolicy` with no
/// change to discovery, keepalives, or the packet path. An outside controller and
/// weighted load-balance are tracked under `OSS-73`.
public enum RelayLinkPolicyKind: String, Sendable, CaseIterable {
    /// Keep every reachable link open; carry on the preferred link keeping up.
    case activeBackup
    /// Keep only the top-preference link open; carry on it.
    case batterySaver
}

// MARK: - RelayLinkPolicy

/// The carrying-link algorithm and the keep-open decision, the one place link
/// behavior is declared. It reads the declared preference (`RelayLinkScorer`), the
/// flap margin, and each link's freshness, and returns which links to keep open
/// and the order to carry traffic on. Nothing here is a fixed threshold or a
/// frozen order: reorder the preference by editing the scorer, or change behavior
/// by selecting another `RelayLinkPolicyKind`.
public enum RelayLinkPolicy {
    /// Runs the policy in force from `RelayTransportPolicy.activeLinkPolicy`.
    public static func plan(for links: [RelayLinkSnapshot]) -> RelayLinkPlan {
        plan(for: links, kind: RelayTransportPolicy.activeLinkPolicy)
    }

    /// Runs a named policy. Pure: the same links always produce the same plan.
    public static func plan(
        for links: [RelayLinkSnapshot], kind: RelayLinkPolicyKind
    ) -> RelayLinkPlan {
        let byPreference = links.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.interfaceName < rhs.interfaceName
        }
        let keepWarm: [String]
        switch kind {
        case .activeBackup:
            keepWarm = byPreference.map(\.interfaceName)
        case .batterySaver:
            keepWarm = byPreference.first.map { [$0.interfaceName] } ?? []
        }
        return RelayLinkPlan(keepWarm: keepWarm, egressOrder: carryingOrder(byPreference))
    }

    /// Ranks links for carrying. A link keeps up when its silence is within the
    /// flap margin of the freshest link; the margin is the larger of the declared
    /// floor and the freshest link's own silence, so the test stays relative when
    /// every link is slow and holds the whole set together during a blackout.
    /// Links keeping up come first in declared preference order, then any lagging
    /// links, so the carrying link is the preferred one keeping up and is never
    /// empty while any link is open.
    private static func carryingOrder(_ byPreference: [RelayLinkSnapshot]) -> [String] {
        guard let bestSilence = byPreference.map(\.silenceMilliseconds).min() else {
            return []
        }
        let margin = max(RelayTransportPolicy.flapMarginFloorMilliseconds, bestSilence)
        let keepingUp = byPreference.filter { link in
            link.silenceMilliseconds - bestSilence <= margin
        }
        let lagging = byPreference.filter { link in
            link.silenceMilliseconds - bestSilence > margin
        }
        return keepingUp.map(\.interfaceName) + lagging.map(\.interfaceName)
    }
}

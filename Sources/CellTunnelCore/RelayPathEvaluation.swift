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

/// The tunables the transport manager reads when it decides whether and how to
/// switch the live relay link. They damp flapping (a margin and a debounce) and
/// bound how long a candidate may take to come up before the manager tries the
/// next one.
public enum RelayTransportPolicy {
    /// The minimum score advantage the best candidate must hold over the active
    /// transport before the manager switches a working link, so a tie or a tiny
    /// attribute change does not move the live link.
    public static let switchScoreMargin = 1

    /// The window the manager coalesces rapid interface changes into a single
    /// switch decision, so an interface that bounces does not trigger repeated
    /// swaps.
    public static let evaluationDebounceMilliseconds = 750

    /// How long the manager waits for a candidate connection to reach ready
    /// before abandoning it and trying the next candidate in the evaluation.
    public static let candidateEstablishTimeoutSeconds = 4

    // MARK: - Multi-link liveness tunables

    /// How often each side sends an empty heartbeat datagram on every warm link.
    /// The relay forwards only non-empty datagrams, so a heartbeat never reaches
    /// WireGuard; it exists only to refresh the receiving side's last-heard time.
    public static let heartbeatIntervalMilliseconds = 250

    /// The miss window for a low-latency link (wired, Wi-Fi LAN, loopback). A link
    /// that has not delivered a heartbeat or datagram within this window is dead,
    /// so failover triggers fast on a stall the connection error did not surface.
    public static let lowLatencyLivenessDeadlineMilliseconds = 400

    /// The miss window for the Apple peer-to-peer link (AWDL). It is loose because
    /// the availability-window duty cycle delivers heartbeats late, so a tight
    /// deadline would declare a working AWDL link dead.
    public static let peerToPeerLivenessDeadlineMilliseconds = 1_200
}

// MARK: - RelayLinkLiveness

/// Decides whether one link is still alive from the last time a heartbeat or
/// datagram arrived on it. A standby link carries no WireGuard data, so it has no
/// other liveness signal; each side stamps the last-heard time per link and asks
/// this type whether the link missed its class deadline. The type is pure: it
/// takes the current time as an argument and computes nothing from the clock, so
/// it is unit tested without Network and shared by the agent and the iPhone.
public struct RelayLinkLiveness: Sendable, Equatable {
    public let linkClass: RelayLinkClass
    public let lastHeardMilliseconds: Int

    public init(linkClass: RelayLinkClass, lastHeardMilliseconds: Int) {
        self.linkClass = linkClass
        self.lastHeardMilliseconds = lastHeardMilliseconds
    }

    /// The miss window for a link class. Low-latency links use the tight window so
    /// failover is fast; the peer-to-peer link uses the loose window because its
    /// duty cycle delivers heartbeats late.
    public static func deadlineMilliseconds(for linkClass: RelayLinkClass) -> Int {
        switch linkClass {
        case .peerToPeer:
            RelayTransportPolicy.peerToPeerLivenessDeadlineMilliseconds
        case .wired, .wifiLan, .cellular, .loopback, .other:
            RelayTransportPolicy.lowLatencyLivenessDeadlineMilliseconds
        }
    }

    /// Whether the link is alive at `nowMilliseconds`: the last heartbeat or
    /// datagram arrived no longer ago than the class deadline. A clock that has
    /// not advanced past the deadline keeps the link alive.
    public func isAlive(atMilliseconds nowMilliseconds: Int) -> Bool {
        nowMilliseconds - lastHeardMilliseconds
            <= Self.deadlineMilliseconds(for: linkClass)
    }
}

// MARK: - RelayLinkSnapshot

/// One warm link as the policy sees it: which interface it runs over, its scored
/// class, and whether it is currently live. The relay keeps one of these per
/// interface and hands the set to the policy whenever liveness or membership
/// changes. It carries no Network object so the policy stays pure and testable.
public struct RelayLinkSnapshot: Sendable, Equatable {
    public let interfaceName: String
    public let linkClass: RelayLinkClass
    public let score: Int
    public let isLive: Bool

    public init(interfaceName: String, linkClass: RelayLinkClass, isLive: Bool) {
        self.interfaceName = interfaceName
        self.linkClass = linkClass
        self.score = RelayLinkScorer.score(
            linkClass: linkClass, isExpensive: false, isConstrained: false
        )
        self.isLive = isLive
    }
}

// MARK: - RelayLinkPlan

/// What the policy decided: which links to keep warm and the egress preference.
/// `keepWarm` lists every interface the relay should dial and heartbeat, ordered
/// best first. `egressOrder` lists only the live interfaces, best first, so the
/// hot path egresses on `egressOrder.first` and reorders only when this plan is
/// recomputed. An empty `egressOrder` means no link is live, which is the
/// any-link-down signal that withdraws routes.
public struct RelayLinkPlan: Sendable, Equatable {
    public let keepWarm: [String]
    public let egressOrder: [String]

    public init(keepWarm: [String], egressOrder: [String]) {
        self.keepWarm = keepWarm
        self.egressOrder = egressOrder
    }

    /// The interface the hot path egresses on, or nil when no link is live.
    public var egressInterfaceName: String? {
        egressOrder.first
    }
}

// MARK: - RelayLinkPolicy

/// The one declarative control point for multi-link behavior. A pure function
/// maps the current set of links to a plan, so changing behavior is one edit
/// here and nothing on the discovery, heartbeat, or per-datagram path moves. The
/// shipped policy is active-backup: keep every reachable link warm and egress on
/// the single highest-scoring live link. Battery (keep only the top link warm),
/// orchestrator (take an external order), and weighted load-balance are later
/// policies that slot in beside `activeBackup` behind `plan(for:)`; they are
/// tracked under `OSS-73`.
public enum RelayLinkPolicy {
    /// Maps the current links to the active plan. The single dispatch point a
    /// later policy mode replaces.
    public static func plan(for links: [RelayLinkSnapshot]) -> RelayLinkPlan {
        activeBackup(links)
    }

    /// Keeps every reachable link warm and egresses on the single highest-scoring
    /// live link. Ties break by interface name so both ends order identically.
    static func activeBackup(_ links: [RelayLinkSnapshot]) -> RelayLinkPlan {
        let ordered = links.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.interfaceName < rhs.interfaceName
        }
        let keepWarm = ordered.map(\.interfaceName)
        let egressOrder = ordered.filter(\.isLive).map(\.interfaceName)
        return RelayLinkPlan(keepWarm: keepWarm, egressOrder: egressOrder)
    }
}

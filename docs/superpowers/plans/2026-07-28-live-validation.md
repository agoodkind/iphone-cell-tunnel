# Live Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the app's user-facing claims against a running machine, after removing the invented resolver and adding a section that shows what the tunnel actually installed.

**Architecture:** Two decisions become pure functions in `Sources/CellTunnelCore` with tests: which resolvers may be published, and where the configuration and the live tunnel disagree. The packet tunnel reports what it installed through the status snapshot it already returns, the app renders that as one more data-driven section, and `celltunnelctl smoke` prints any disagreement so it is catchable without a screen. The live runs then exercise the claims in a machine.

**Tech Stack:** Swift 6, Swift Testing (`@Test` / `#expect`), SwiftPM for `Sources/CellTunnelCore` and `Tests/CellTunnelCoreTests`, Tuist for the app targets, NetworkExtension, Network.

## Global Constraints

- The tunnel never invents a resolver. It publishes only what the configuration names, and never for an address family it cannot carry.
- Decisions are pure functions in `Sources/CellTunnelCore` with tests. The tunnel supplies observations and applies the result.
- Tests live in `Tests/CellTunnelCoreTests` and use Swift Testing, not XCTest.
- A new file in `Sources/` must be reachable from a SwiftPM target or the `lint-deadcode` gate fails it.
- Enum cases are declared in alphabetical order; `lint-swiftlint` enforces it.
- An access modifier goes on each member, never on an `extension`.
- Vertical whitespace is limited to a single empty line.
- SwiftLint rejects an optional `Bool` return, and any `swiftlint:disable` comment is a hard error, so a tri-state is an enum rather than `Bool?`.
- Comments explain why, never what. No em dashes anywhere.
- Configurations carry private keys. Copies live only in a gitignored directory and the originals are never edited.
- Build and gate with the repo's dev tool, not `swift build`:
  `SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic swift Tools/cell-tunnel-dev.swift build mac Debug`
- Run package tests with `swift test --filter <SuiteName>` from the repo root.

---

### Task 1: Publish only the resolvers the configuration names

The tunnel substitutes `1.1.1.1` and `2606:4700:4700::1111` when a configuration names no resolver and the tunnel captures all traffic. That decides where a person's name queries go on their behalf. Name resolution is not what carries traffic, so a configuration that names no resolver still passes packets; only names stop resolving through the tunnel, and choosing a resolver is the configuration's job.

**Files:**
- Create: `Sources/CellTunnelCore/TunnelResolvers.swift`
- Modify: `Apps/macOS/TunnelProvider/Runtime/RouteGate.swift:36-41, 154-166`
- Test: `Tests/CellTunnelCoreTests/TunnelResolversTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `publishableResolvers(named:tunnelCarriesIPv4:tunnelCarriesIPv6:) -> [String]`, a `public` free function. Task 3 compares its result against what the configuration named.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/TunnelResolversTests.swift`:

```swift
//
//  TunnelResolversTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-28.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

@Suite("Publishable resolvers")
struct TunnelResolversTests {
  /// A configuration that names no resolver gets none. Substituting one decides
  /// where a person's queries go on their behalf.
  @Test("naming no resolver publishes none")
  func namingNonePublishesNone() {
    let published = publishableResolvers(
      named: [], tunnelCarriesIPv4: true, tunnelCarriesIPv6: true)
    #expect(published.isEmpty)
  }

  @Test("both families named and carried are both published")
  func bothNamedAndCarried() {
    let published = publishableResolvers(
      named: ["10.250.10.1", "3d06:bad:b01:a::1"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: true)
    #expect(published == ["10.250.10.1", "3d06:bad:b01:a::1"])
  }

  /// A resolver the tunnel cannot reach has no source address to be answered from,
  /// so its queries would leave over a physical interface.
  @Test("a resolver for an uncarried family is dropped")
  func uncarriedFamilyIsDropped() {
    let published = publishableResolvers(
      named: ["10.250.10.1", "3d06:bad:b01:a::1"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: false)
    #expect(published == ["10.250.10.1"])
  }

  @Test("naming only an uncarried family publishes none")
  func onlyUncarriedFamilyPublishesNone() {
    let published = publishableResolvers(
      named: ["3d06:bad:b01:a::1"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: false)
    #expect(published.isEmpty)
  }

  /// Order is the configuration's preference, so it survives filtering.
  @Test("the configuration's order survives")
  func orderSurvives() {
    let published = publishableResolvers(
      named: ["1.1.1.1", "8.8.8.8", "9.9.9.9"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: true)
    #expect(published == ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
  }

  /// A value that parses as neither family is not something to publish blindly.
  @Test("an unparseable entry is dropped")
  func unparseableEntryIsDropped() {
    let published = publishableResolvers(
      named: ["not-an-address", "1.1.1.1"],
      tunnelCarriesIPv4: true,
      tunnelCarriesIPv6: true)
    #expect(published == ["1.1.1.1"])
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TunnelResolversTests`
Expected: FAIL to compile, `cannot find 'publishableResolvers' in scope`.

- [ ] **Step 3: Write the decision**

Create `Sources/CellTunnelCore/TunnelResolvers.swift`:

```swift
//
//  TunnelResolvers.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-28.
//  Copyright © 2026, all rights reserved.
//

import Network

/// Which of the resolvers a configuration names the tunnel may publish.
///
/// Only what the configuration names is eligible. Substituting an address when a
/// configuration names none would decide where a person's queries go on their
/// behalf, and name resolution is not what carries traffic: a configuration naming
/// no resolver still passes packets, and only names stop resolving through the
/// tunnel.
///
/// A named resolver is dropped when the tunnel holds no address in its family,
/// because it would then have no source address to be answered from and its queries
/// would leave over a physical interface.
public func publishableResolvers(
  named: [String],
  tunnelCarriesIPv4: Bool,
  tunnelCarriesIPv6: Bool
) -> [String] {
  named.filter { address in
    if IPv4Address(address) != nil {
      return tunnelCarriesIPv4
    }
    if IPv6Address(address) != nil {
      return tunnelCarriesIPv6
    }
    return false
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TunnelResolversTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Call it from the tunnel and delete the substitution**

In `Apps/macOS/TunnelProvider/Runtime/RouteGate.swift`, delete these lines including the comment above them at lines 36-41:

```swift
  /// The public resolvers published for an all-traffic config that supplies no
  /// `DNS =` line, so names resolve over the tunnel. Cloudflare's anycast
  /// addresses are reachable from any full-tunnel exit. Each is published only
  /// when the tunnel captures that address family.
  private static let allTrafficFallbackIPv4DNSServer = "1.1.1.1"
  private static let allTrafficFallbackIPv6DNSServer = "2606:4700:4700::1111"
```

Replace `resolvedDNSServersLocked()` and its comment at lines 145-166 with:

```swift
  /// The resolvers to publish, which are the ones the configuration names and no
  /// others. A named resolver whose family the tunnel does not carry is dropped,
  /// since it would have no source address to be answered from.
  private func resolvedDNSServersLocked() -> [String] {
    publishableResolvers(
      named: programDNSServers,
      tunnelCarriesIPv4: tunnelCarriesIPv4Locked(),
      tunnelCarriesIPv6: tunnelCarriesIPv6Locked()
    )
  }
```

Add `import CellTunnelCore` to the file's imports, keeping them alphabetical.

`capturesAllIPv4TrafficLocked()`, `capturesAllIPv6TrafficLocked()`, and `leadingBit(of:)` lose their only callers. Delete all three and the `IPv4Address`/`IPv6Address` uses they carried.

- [ ] **Step 6: Build and gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0. The dead-code gate is the one that catches a leftover helper.

- [ ] **Step 7: Commit**

```bash
git add Sources/CellTunnelCore/TunnelResolvers.swift \
  Tests/CellTunnelCoreTests/TunnelResolversTests.swift \
  Apps/macOS/TunnelProvider/Runtime/RouteGate.swift
git commit -S -m "Publish only the resolvers the configuration names" \
  -m "The tunnel substituted public addresses when a configuration named none, deciding where a person's queries go on their behalf, and a configuration that names no resolver still carries traffic." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 2: Report what the tunnel installed

Nothing outside the tunnel can see which routes it captured or which resolvers it published, so a route that failed to install or a resolver that was withheld is invisible until traffic misbehaves. The tunnel already answers a status request; this adds those values to that answer.

**Files:**
- Create: `Sources/CellTunnelCore/TunnelInEffect.swift`
- Modify: `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`
- Modify: `Apps/macOS/TunnelProvider/Runtime/RouteGate.swift`
- Modify: `Apps/macOS/TunnelProvider/PacketTunnelProvider.swift:351-366`
- Test: `Tests/CellTunnelCoreTests/TunnelInEffectTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 directly.
- Produces: `TunnelInEffect`, a `public struct` conforming to `Codable, Equatable, Sendable` with `public var capturedIPv4Routes: [String]`, `public var capturedIPv6Routes: [String]`, `public var publishedResolvers: [String]`, `public var searchDomains: [String]`, and a memberwise `public init` defaulting every field to empty. `TunnelDaemonStatusSnapshot.inEffect: TunnelInEffect?` as the last initializer parameter, defaulting to `nil`. `RouteGate.inEffectValues() -> TunnelInEffect`. Tasks 3, 4, and 5 all read `inEffect`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/TunnelInEffectTests.swift`:

```swift
//
//  TunnelInEffectTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-28.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import CellTunnelCore

@Suite("Tunnel in-effect values")
struct TunnelInEffectTests {
  /// An older agent omits the field, so a client has to tell absent from empty:
  /// absent means the agent did not report, empty means it reported nothing captured.
  @Test("a snapshot without the field decodes with it absent")
  func absentFieldDecodes() throws {
    let json = Data(#"{"running":true,"routeState":"installed","peerState":"wireGuardConfigured","ipv4Address":"","ipv6Address":"","discovery":{"services":[],"phase":"stopped"}}"#.utf8)
    let snapshot = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: json)
    #expect(snapshot.inEffect == nil)
  }

  @Test("the values survive a round trip")
  func valuesRoundTrip() throws {
    let inEffect = TunnelInEffect(
      capturedIPv4Routes: ["0.0.0.0/0"],
      capturedIPv6Routes: ["::/0"],
      publishedResolvers: ["10.250.10.1"],
      searchDomains: ["example.test"]
    )
    var snapshot = TunnelDaemonStatusSnapshot()
    snapshot.inEffect = inEffect
    let decoded = try JSONDecoder().decode(
      TunnelDaemonStatusSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded.inEffect == inEffect)
  }

  @Test("an empty value is not the same as no value")
  func emptyIsNotAbsent() {
    #expect(TunnelInEffect() != nil)
    #expect(TunnelInEffect().capturedIPv4Routes.isEmpty)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TunnelInEffectTests`
Expected: FAIL to compile, `cannot find 'TunnelInEffect' in scope`.

- [ ] **Step 3: Write the type**

Create `Sources/CellTunnelCore/TunnelInEffect.swift`:

```swift
//
//  TunnelInEffect.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-28.
//  Copyright © 2026, all rights reserved.
//

/// What the packet tunnel actually installed, as opposed to what a configuration
/// asked for.
///
/// The two can differ, and the difference is invisible from outside the tunnel until
/// traffic misbehaves. Reporting the installed values lets a route that never took
/// effect or a resolver that was withheld be seen directly rather than inferred.
public struct TunnelInEffect: Codable, Equatable, Sendable {
  public var capturedIPv4Routes: [String]
  public var capturedIPv6Routes: [String]
  public var publishedResolvers: [String]
  public var searchDomains: [String]

  public init(
    capturedIPv4Routes: [String] = [],
    capturedIPv6Routes: [String] = [],
    publishedResolvers: [String] = [],
    searchDomains: [String] = []
  ) {
    self.capturedIPv4Routes = capturedIPv4Routes
    self.capturedIPv6Routes = capturedIPv6Routes
    self.publishedResolvers = publishedResolvers
    self.searchDomains = searchDomains
  }
}
```

- [ ] **Step 4: Carry it on the snapshot**

In `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, add this stored property immediately after `vpnProfileState`:

```swift
  /// What the packet tunnel installed, absent when the reporting agent predates the
  /// field. Absent and empty differ: absent means unreported, empty means nothing
  /// captured.
  public var inEffect: TunnelInEffect?
```

Add the matching parameter as the last one in the memberwise `public init`, defaulting to `nil`, and assign it in the body. Every existing call site keeps compiling because every parameter already has a default.

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter TunnelInEffectTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Report the values from the tunnel**

In `Apps/macOS/TunnelProvider/Runtime/RouteGate.swift`, add this method inside the type, after `recordedAddresses()`:

```swift
  /// What this gate has installed right now, for the status the provider reports.
  ///
  /// Withheld routes read as empty rather than as the program set, because the
  /// question is what took effect, not what would take effect if the link came up.
  func inEffectValues() -> TunnelInEffect {
    lock.lock()
    defer { lock.unlock() }
    let dnsSettings = installed ? makeDNSSettingsLocked() : nil
    return TunnelInEffect(
      capturedIPv4Routes: installed ? programIPv4Routes.map(Self.describe) : [],
      capturedIPv6Routes: installed ? programIPv6Routes.map(Self.describe) : [],
      publishedResolvers: dnsSettings?.servers ?? [],
      searchDomains: dnsSettings?.searchDomains ?? []
    )
  }

  /// A route as `address/mask` text, so a reader compares the same shape a
  /// configuration writes.
  private static func describe(_ route: NEIPv4Route) -> String {
    "\(route.destinationAddress)/\(route.destinationSubnetMask)"
  }

  private static func describe(_ route: NEIPv6Route) -> String {
    "\(route.destinationAddress)/\(route.destinationNetworkPrefixLength)"
  }
```

In `Apps/macOS/TunnelProvider/PacketTunnelProvider.swift`, add one argument to the `TunnelDaemonStatusSnapshot` built at lines 354-365, after `relayProtocol`:

```swift
      inEffect: routeGate.inEffectValues()
```

- [ ] **Step 7: Build and gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add Sources/CellTunnelCore/TunnelInEffect.swift \
  Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift \
  Tests/CellTunnelCoreTests/TunnelInEffectTests.swift \
  Apps/macOS/TunnelProvider/Runtime/RouteGate.swift \
  Apps/macOS/TunnelProvider/PacketTunnelProvider.swift
git commit -S -m "Report which routes and resolvers the tunnel installed" \
  -m "Nothing outside the tunnel could see what took effect, so a route that never installed or a resolver that was withheld stayed invisible until traffic misbehaved." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 3: Find where the configuration and the tunnel disagree

A configuration asking for a route the tunnel never installed reads as success everywhere. Comparing the two turns that into a named disagreement.

**Files:**
- Create: `Sources/CellTunnelCore/TunnelValueMismatch.swift`
- Test: `Tests/CellTunnelCoreTests/TunnelValueMismatchTests.swift`

**Interfaces:**
- Consumes: `TunnelInEffect` from Task 2.
- Produces: `TunnelValueMismatch`, a `public struct` conforming to `Codable, Equatable, Sendable` with `public let field: String`, `public let asked: String`, and `public let inEffect: String`. And `tunnelMismatches(askedIPv4Routes:askedIPv6Routes:askedResolvers:inEffect:) -> [TunnelValueMismatch]`, a `public` free function. Tasks 4 and 5 render and print its result.

- [ ] **Step 1: Write the failing test**

Create `Tests/CellTunnelCoreTests/TunnelValueMismatchTests.swift`:

```swift
//
//  TunnelValueMismatchTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-28.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

@Suite("Tunnel value mismatches")
struct TunnelValueMismatchTests {
  @Test("matching values report nothing")
  func matchingValuesReportNothing() {
    let mismatches = tunnelMismatches(
      askedIPv4Routes: ["0.0.0.0/0"],
      askedIPv6Routes: ["::/0"],
      askedResolvers: ["10.250.10.1"],
      inEffect: TunnelInEffect(
        capturedIPv4Routes: ["0.0.0.0/0"],
        capturedIPv6Routes: ["::/0"],
        publishedResolvers: ["10.250.10.1"]
      )
    )
    #expect(mismatches.isEmpty)
  }

  /// A configuration naming every address while the tunnel captured a subset is the
  /// failure that reads as success everywhere else.
  @Test("a route that did not install is named")
  func uninstalledRouteIsNamed() {
    let mismatches = tunnelMismatches(
      askedIPv4Routes: ["0.0.0.0/0"],
      askedIPv6Routes: [],
      askedResolvers: [],
      inEffect: TunnelInEffect(capturedIPv4Routes: ["10.0.0.0/8"])
    )
    #expect(mismatches.count == 1)
    #expect(mismatches[0].field == "IPv4 routes")
    #expect(mismatches[0].asked == "0.0.0.0/0")
    #expect(mismatches[0].inEffect == "10.0.0.0/8")
  }

  /// A resolver the tunnel withheld because it cannot carry that family is a real
  /// difference the reader needs, not a silent filter.
  @Test("a withheld resolver is named")
  func withheldResolverIsNamed() {
    let mismatches = tunnelMismatches(
      askedIPv4Routes: [],
      askedIPv6Routes: [],
      askedResolvers: ["10.250.10.1", "3d06:bad:b01:a::1"],
      inEffect: TunnelInEffect(publishedResolvers: ["10.250.10.1"])
    )
    #expect(mismatches.count == 1)
    #expect(mismatches[0].field == "Resolvers")
  }

  @Test("several disagreements are all reported")
  func severalDisagreementsReported() {
    let mismatches = tunnelMismatches(
      askedIPv4Routes: ["0.0.0.0/0"],
      askedIPv6Routes: ["::/0"],
      askedResolvers: ["1.1.1.1"],
      inEffect: TunnelInEffect()
    )
    #expect(mismatches.count == 3)
  }

  /// Order is presentation, not meaning, so the same set in another order agrees.
  @Test("order alone is not a disagreement")
  func orderAloneIsNotADisagreement() {
    let mismatches = tunnelMismatches(
      askedIPv4Routes: ["10.0.0.0/8", "192.168.0.0/16"],
      askedIPv6Routes: [],
      askedResolvers: [],
      inEffect: TunnelInEffect(capturedIPv4Routes: ["192.168.0.0/16", "10.0.0.0/8"])
    )
    #expect(mismatches.isEmpty)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TunnelValueMismatchTests`
Expected: FAIL to compile, `cannot find 'tunnelMismatches' in scope`.

- [ ] **Step 3: Write the comparison**

Create `Sources/CellTunnelCore/TunnelValueMismatch.swift`:

```swift
//
//  TunnelValueMismatch.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-28.
//  Copyright © 2026, all rights reserved.
//

// MARK: - TunnelValueMismatch

/// One place a configuration and the running tunnel disagree.
///
/// A configuration asking for a route the tunnel never installed reads as success
/// everywhere, so the disagreement has to be named before anyone can act on it.
public struct TunnelValueMismatch: Codable, Equatable, Sendable {
  public let field: String
  public let asked: String
  public let inEffect: String

  public init(field: String, asked: String, inEffect: String) {
    self.field = field
    self.asked = asked
    self.inEffect = inEffect
  }
}

// MARK: - Comparison

private let emptyValueText = "(none)"

/// Every disagreement between what a configuration asked for and what took effect.
///
/// Order is presentation rather than meaning, so the same set written in another
/// order agrees. An empty side reads as `(none)` so a reader sees which side is
/// missing rather than a blank.
public func tunnelMismatches(
  askedIPv4Routes: [String],
  askedIPv6Routes: [String],
  askedResolvers: [String],
  inEffect: TunnelInEffect
) -> [TunnelValueMismatch] {
  var mismatches: [TunnelValueMismatch] = []
  let comparisons = [
    ("IPv4 routes", askedIPv4Routes, inEffect.capturedIPv4Routes),
    ("IPv6 routes", askedIPv6Routes, inEffect.capturedIPv6Routes),
    ("Resolvers", askedResolvers, inEffect.publishedResolvers),
  ]
  for (field, asked, actual) in comparisons where Set(asked) != Set(actual) {
    mismatches.append(
      TunnelValueMismatch(
        field: field,
        asked: describe(asked),
        inEffect: describe(actual)
      ))
  }
  return mismatches
}

private func describe(_ values: [String]) -> String {
  values.isEmpty ? emptyValueText : values.joined(separator: ", ")
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TunnelValueMismatchTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Build and gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/CellTunnelCore/TunnelValueMismatch.swift \
  Tests/CellTunnelCoreTests/TunnelValueMismatchTests.swift
git commit -S -m "Name where a configuration and the running tunnel disagree" \
  -m "A configuration asking for a route the tunnel never installed read as success everywhere, so nothing surfaced the difference." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 4: Show the active configuration on screen

Nothing on screen says which routes, resolvers, or keepalive the running tunnel is using, so a person cannot tell a working tunnel from one that quietly dropped half its routes. The status screen already renders an ordered list of label-and-value sections, so this is a data change.

**Files:**
- Modify: `Apps/iOS/Views/RelayScreenModel.swift`
- Modify: `Apps/iOS/Services/RelayController.swift`

**Interfaces:**
- Consumes: `TunnelInEffect` from Task 2 and `tunnelMismatches(askedIPv4Routes:askedIPv6Routes:askedResolvers:inEffect:)` from Task 3.
- Produces: `RelayScreenModel.tunnelSection: ConnectionSection?`, appended by both `sections` and `macSections`.

- [ ] **Step 1: Mirror the values onto the controller**

In `Apps/iOS/Services/RelayController.swift`, add this stored property beside the other mirrored snapshot values, after `relayServerIPv6Address`:

```swift
  /// What the packet tunnel installed, mirrored from the status snapshot, absent
  /// when the reporting agent predates the field.
  var inEffect: TunnelInEffect?
```

In the same file, in the function that applies a sample to the controller, assign it alongside the other `assign` calls:

```swift
    assign(\.inEffect, sample.inEffect)
```

Add `var inEffect: TunnelInEffect?` to `RelayStatusSample` and set it in `RelayStatusSample.init(snapshot:)` with `inEffect = snapshot.inEffect`.

- [ ] **Step 2: Add the section**

In `Apps/iOS/Views/RelayScreenModel.swift`, add this constant beside the other section titles near the top of the file:

```swift
private let tunnelSectionTitle = "Tunnel"
```

Add this computed property in the `// MARK: - Sections` area, after `currentSpeedSection`:

```swift
  // What the running tunnel installed. Absent until the tunnel reports, so the
  // section is absent rather than showing empty rows for a tunnel that is not up.
  // A row whose asked-for and in-effect values differ shows both, because that
  // difference is the whole reason to look.
  private var tunnelSection: ConnectionSection? {
    guard let inEffect = controller.inEffect else {
      return nil
    }
    let mismatches = tunnelMismatches(
      askedIPv4Routes: controller.askedIPv4Routes,
      askedIPv6Routes: controller.askedIPv6Routes,
      askedResolvers: controller.askedResolvers,
      inEffect: inEffect
    )
    var rows: [ConnectionRow] = [
      ConnectionRow(
        label: "IPv4 Routes",
        value: describeValues(inEffect.capturedIPv4Routes)),
      ConnectionRow(
        label: "IPv6 Routes",
        value: describeValues(inEffect.capturedIPv6Routes)),
      ConnectionRow(
        label: "Resolvers",
        value: describeValues(inEffect.publishedResolvers)),
    ]
    for mismatch in mismatches {
      rows.append(
        ConnectionRow(
          label: "\(mismatch.field) asked",
          value: mismatch.asked))
    }
    return ConnectionSection(title: tunnelSectionTitle, rows: rows)
  }

  private func describeValues(_ values: [String]) -> String {
    values.isEmpty ? emptyValuePlaceholder : values.joined(separator: ", ")
  }
```

Append it in `sections`, immediately before `result.append(contentsOf: connectionSections)`:

```swift
    if let tunnelSection {
      result.append(tunnelSection)
    }
```

Append it in `macSections`, immediately before `var connection = [deviceSection, peerSection]`:

```swift
    if let tunnelSection {
      result.append(tunnelSection)
    }
```

- [ ] **Step 3: Carry the asked-for values**

In `Apps/iOS/Services/RelayController.swift`, add these three properties beside `inEffect`:

```swift
  /// What the active configuration asked for, parsed once when it becomes active, so
  /// the screen can show it beside what took effect.
  var askedIPv4Routes: [String] = []
  var askedIPv6Routes: [String] = []
  var askedResolvers: [String] = []
```

Add this method to the same type, and call it from the Mac path that already fetches an active configuration's text, passing the text it received:

```swift
  /// Records what the active configuration asked for, so the screen can show it
  /// beside what took effect. Parsed once on activation rather than per render,
  /// because the text does not change while a configuration stays active.
  func noteAskedValues(configText: String) {
    guard let parsed = try? WireGuardConfigParser.parse(configText) else {
      askedIPv4Routes = []
      askedIPv6Routes = []
      askedResolvers = []
      return
    }
    var ipv4: [String] = []
    var ipv6: [String] = []
    for prefix in parsed.peer.allowedIPs {
      let text = "\(prefix.address)/\(prefix.prefixLength)"
      if IPv4Address(prefix.address) != nil {
        ipv4.append(text)
      } else {
        ipv6.append(text)
      }
    }
    askedIPv4Routes = ipv4
    askedIPv6Routes = ipv6
    askedResolvers = parsed.interface.dnsServers
  }
```

Add `import Network` to the file's imports, keeping them alphabetical. If `AddressPrefix` names its members differently from `address` and `prefixLength`, read the declaration in `Sources/CellTunnelCore/WireGuardConfigParser.swift` and use its actual names rather than these.

- [ ] **Step 4: Build and gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Apps/iOS/Views/RelayScreenModel.swift Apps/iOS/Services/RelayController.swift
git commit -S -m "Show which routes and resolvers the running tunnel installed" \
  -m "Nothing on screen distinguished a working tunnel from one that quietly dropped half its routes." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 5: Print the disagreement from smoke

A disagreement visible only on a screen cannot be caught by a script or a machine run. The smoke command already prints a status block, so this adds the lines to it.

**Files:**
- Modify: `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`

**Interfaces:**
- Consumes: `TunnelInEffect` from Task 2 and `tunnelMismatches(...)` from Task 3.
- Produces: additional lines in `TunnelDaemonStatusSnapshot.renderedOutput`, named `in_effect_ipv4_routes`, `in_effect_ipv6_routes`, `in_effect_resolvers`, and one `mismatch.<field>=asked <asked> in-effect <in-effect>` line per disagreement.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CellTunnelCoreTests/TunnelInEffectTests.swift`, inside the existing suite:

```swift
  /// A disagreement has to reach a script, not only a screen, or a machine run
  /// cannot catch it.
  @Test("the rendered status names a disagreement")
  func renderedStatusNamesADisagreement() {
    var snapshot = TunnelDaemonStatusSnapshot()
    snapshot.inEffect = TunnelInEffect(capturedIPv4Routes: ["10.0.0.0/8"])
    let rendered = snapshot.renderedOutput
    #expect(rendered.contains("in_effect_ipv4_routes=10.0.0.0/8"))
  }

  @Test("the rendered status omits the lines when nothing is reported")
  func renderedStatusOmitsAbsentValues() {
    let rendered = TunnelDaemonStatusSnapshot().renderedOutput
    #expect(!rendered.contains("in_effect_"))
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TunnelInEffectTests`
Expected: FAIL, the rendered output does not contain `in_effect_ipv4_routes`.

- [ ] **Step 3: Render the values**

In `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, inside `renderedOutput`, add this immediately before the `vpnProfileState` block:

```swift
    if let inEffect {
      lines.append("in_effect_ipv4_routes=\(inEffect.capturedIPv4Routes.joined(separator: ","))")
      lines.append("in_effect_ipv6_routes=\(inEffect.capturedIPv6Routes.joined(separator: ","))")
      lines.append("in_effect_resolvers=\(inEffect.publishedResolvers.joined(separator: ","))")
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TunnelInEffectTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Build and gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift \
  Tests/CellTunnelCoreTests/TunnelInEffectTests.swift
git commit -S -m "Print what the tunnel installed in the status output" \
  -m "A disagreement between a configuration and the running tunnel was visible only on a screen, so no script or machine run could catch it." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 6: Run the resolver matrix in a machine

Six configuration variants decide whether the tunnel publishes exactly what was named. Nothing before this point has run against a real tunnel.

**Files:**
- Create: six configuration copies in a gitignored directory, derived from the two originals, never editing an original.

**Interfaces:**
- Consumes: everything from Tasks 1 through 5.
- Produces: a recorded result per variant, with the state that produced it.

- [ ] **Step 1: Bring up the machine and pair a phone**

Run the dev tool's `guest` command, which builds every target on the host, verifies each signature, copies the products in, starts the agent under launchd, boots a simulator inside the machine, and waits for the two to pair:

```bash
CELL_TUNNEL_GUEST_PASSWORD=<guest account password> \
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift guest <machine-name> Debug
```

Stop if it does not reach a paired state. Every later step needs a phone connected, because the Mac routes through it.

- [ ] **Step 2: Stage the variants**

Copy the two originals into a gitignored directory and derive four more, never editing an original:

```bash
STAGE=.make/validation-configs
mkdir -p "$STAGE"
cp ~/Desktop/celltunnel.conf "$STAGE/scoped-no-dns.conf"
cp ~/Desktop/celltunnel-all-traffic.conf "$STAGE/full-both-dns.conf"
# Scoped routes with resolvers, from the full-tunnel file's DNS line.
DNSLINE=$(grep '^DNS' ~/Desktop/celltunnel-all-traffic.conf)
awk -v d="$DNSLINE" '/^Address/ {print; print d; next} {print}' \
  ~/Desktop/celltunnel.conf > "$STAGE/scoped-with-dns.conf"
# Full tunnel with no resolvers.
grep -v '^DNS' ~/Desktop/celltunnel-all-traffic.conf > "$STAGE/full-no-dns.conf"
# Full tunnel with only one family's resolvers.
sed 's/^DNS = 10.250.10.1.*/DNS = 10.250.10.1, 1.1.1.1/' \
  ~/Desktop/celltunnel-all-traffic.conf > "$STAGE/full-ipv4-dns.conf"
sed 's/^DNS = 10.250.10.1.*/DNS = 3d06:bad:b01:a::1, 2606:4700:4700::1111/' \
  ~/Desktop/celltunnel-all-traffic.conf > "$STAGE/full-ipv6-dns.conf"
```

Confirm `.make/` is gitignored before writing there, and confirm each derived file still parses by importing it once.

- [ ] **Step 3: Confirm the loaded provider is the build under test**

Inside the machine, find the running extension and the bundle it loaded from:

```bash
pgrep -fl CellTunnelTunnelProvider
lsof -p "$(pgrep -f CellTunnelTunnelProvider | head -1)" 2>/dev/null \
  | grep -a 'CellTunnelTunnelProvider.appex'
```

Confirm the path names the build just copied in, and not a copy registered from an earlier install. The system loads the extension from the saved profile's provider bundle identifier, which can resolve to a different build, and that has already turned an installed build's behavior into an apparent defect in current source. Stop here if they disagree, because every routing, resolver, and counter result after this point would describe the wrong build.

- [ ] **Step 4: Run each variant**

For each of the six, activate the configuration, start routing, then read `celltunnelctl status` and record `in_effect_resolvers` against what the configuration named. Expected per the matrix: naming none publishes none; naming both families publishes both; naming one family publishes only that one; and no variant ever publishes an address the configuration did not name.

- [ ] **Step 5: Check where queries went**

With the full tunnel active and resolvers named, resolve a name and confirm the query left through the tunnel. With the full tunnel active and no resolvers named, resolve a name and record where the query went. The machine's own resolver usually sits on a directly connected subnet whose route is more specific than a default route, so it may still answer off-tunnel. Record what happened rather than what was expected.

- [ ] **Step 6: Record the findings**

Write each result with the configuration that produced it. A finding that only reproduces live is recorded with the state that produced it.

---

### Task 7: Run the remaining claims in a machine

Four claims remain unproven against a running app: the switched-off profile, full-tunnel routing, the first-run screen, and the counter directions.

**Files:**
- None. This task runs the app and records what it observed.

**Interfaces:**
- Consumes: everything from Tasks 1 through 6, including the confirmed provider build.

- [ ] **Step 1: The switched-off profile**

With a configuration active and a phone paired, switch the VPN profile off in System Settings while the app is running. Confirm the screen names the situation, offers to open System Settings, shows what to do there, and presents no routing switch. Confirm it reaches that state without restarting the app.

- [ ] **Step 2: Full-tunnel routing**

Activate the full-tunnel configuration and start routing. Read the routing table and confirm every address the configuration named is present, not a subset. The `smoke` command refuses an all-traffic configuration by design, so use `start` with a peer already selected.

- [ ] **Step 3: The first-run screen**

With no configuration imported, confirm the title, subtitle, and button all describe importing a configuration, and that the button presents the file picker.

- [ ] **Step 4: Counter directions**

Send bulk traffic in one direction through the relay, using the speedtest server the configurations pin in their allowed addresses. Confirm the speed and lifetime figures name that direction on the Mac, then repeat and confirm the same on the phone.

- [ ] **Step 5: Reset keeps the library**

Import two configurations, activate one, then reset. Confirm the library still holds both and only the active selection cleared.

- [ ] **Step 6: Record the findings**

Write each result with the state that produced it, and open a ticket for any claim that failed.

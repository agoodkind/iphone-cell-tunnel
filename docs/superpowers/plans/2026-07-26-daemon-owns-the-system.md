# Daemon Owns the System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac agent a real daemon that starts at login and advertises on its own, so an iPhone can find the Mac without the app being open.

**Architecture:** The agent gains two launchd keys so launchd loads it at login and restarts it if it stops. Its startup path starts the control listener directly rather than waiting for a client request, which is what publishes the record the iPhone browses for. Routing stays off after any restart and the user turns it back on, so nothing about the routing choice is persisted or restored.

**Tech Stack:** Swift 6, Swift Testing (`@Test` / `#expect`), SwiftPM for `Sources/CellTunnelCore` and `Tests/CellTunnelCoreTests`, Tuist for the app targets, launchd via `SMAppService`.

## Global Constraints

- The app group identifier is `group.io.goodkind.CellTunnel`, available in Swift as `cellTunnelAppGroupIdentifier` from `CellTunnelCore`. Never hardcode the literal in Swift.
- The mach service name is `io.goodkind.celltunnel-agent`, available as `agentMachServiceName`. Never hardcode it.
- Routing must be off after any restart of the agent, for any reason. Nothing about the routing choice is written to disk, and the agent never turns routing on by itself.
- Build and gate with the repo's dev tool, not `swift build`:
  `SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic swift Tools/cell-tunnel-dev.swift build mac Debug`
- Run package tests with `swift test --filter <SuiteName>` from the repo root.
- Every gate must pass: `lint-swiftlint`, `lint-format`, `lint-complexity`, `lint-deadcode`, `swiftcheck-extra`, `audit`. A new file in `Sources/` must be reachable from a SwiftPM target or `lint-deadcode` fails it.
- Enum cases must be declared in alphabetical order; `lint-swiftlint` enforces it.
- An access modifier goes on each member, not on the `extension`; `lint-format` and `lint-swiftlint` disagree otherwise. Prefer declaring members inside the type.
- Vertical whitespace is limited to a single empty line.

---

### Task 1: Load the agent at login and keep it loaded

The launch agent plist declares a mach service but sets neither `RunAtLoad` nor `KeepAlive`, so launchd starts the agent only when a client dials the service and never restarts it. After a reboot with the app closed, no agent exists.

**Files:**
- Modify: `Templates/Plists/agent-launchd.plist.template`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a generated plist at `Generated/CellTunnelAgent/agent-launchd.plist` carrying `RunAtLoad` and `KeepAlive`. Task 2 relies on the agent being resident.

- [ ] **Step 1: Add the two keys**

In `Templates/Plists/agent-launchd.plist.template`, insert these keys immediately after the `MachServices` dict closes and before `AssociatedBundleIdentifiers`:

```xml
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
```

Keep the existing keys and their order otherwise unchanged.

- [ ] **Step 2: Regenerate and confirm the rendered plist**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Then:
```bash
plutil -p Generated/CellTunnelAgent/agent-launchd.plist
```
Expected: the printed dictionary contains `"RunAtLoad" => 1` and `"KeepAlive" => 1`, alongside the existing `Label`, `BundleProgram`, `MachServices`, `AssociatedBundleIdentifiers`, and `ProcessType` keys.

- [ ] **Step 3: Confirm the built bundle carries it**

Run:
```bash
plutil -p Products/Debug/CellTunnelAgent.app/Contents/Library/LaunchAgents/agent-launchd.plist
```
Expected: same two keys present.

- [ ] **Step 4: Commit**

```bash
git add Templates/Plists/agent-launchd.plist.template Generated/CellTunnelAgent/agent-launchd.plist
git commit -S -m "Load the agent at login and restart it if it stops" \
  -m "launchd started the agent only when a client dialled its service, so after a reboot with no app open nothing advertised and an iPhone browsing for the Mac found nothing." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 2: Advertise at startup without waiting for a client

`AgentRuntime.start()` in `Apps/macOS/Agent/main.swift:40-52` registers the launch agent and starts the XPC listener, then stops. It never calls `ensureControlListenerStarted()`, which is the only thing that publishes the Bonjour record the iPhone browses for. That function's four callers are all client-request handlers, at `AgentTunnelController+Control.swift:63` and `AgentTunnelController+Requests.swift:104, 201, 257`, so a launchd-started agent stays silent until a client asks it to pair. The iPhone cannot send that request, because it reaches the Mac over the local network rather than through the mach service.

**Files:**
- Modify: `Apps/macOS/Agent/AgentTunnelController+Control.swift`
- Modify: `Apps/macOS/Agent/main.swift:167-171`

**Interfaces:**
- Consumes: a resident agent from Task 1.
- Produces: `AgentTunnelController.startAdvertising()`, an `async` method taking no arguments and returning nothing, called once from the composition root.

- [ ] **Step 1: Add the startup advertise**

Add this method to `Apps/macOS/Agent/AgentTunnelController+Control.swift`, inside the existing `extension AgentTunnelController`, immediately after `ensureControlListenerStarted()` ends at line 49:

```swift
  /// Publishes the record the iPhone browses for, without waiting to be asked.
  ///
  /// The iPhone finds the Mac by browsing for the control listener, and nothing
  /// else publishes it. The iPhone reaches the Mac over the local network rather
  /// than the mach service, so it cannot send the request that would start the
  /// listener. An agent that waits for a request is therefore unreachable by the
  /// one device it exists to serve.
  ///
  /// A failure here is not fatal. The agent keeps serving requests, and the first
  /// client request retries the same call.
  func startAdvertising() async {
    do {
      try await ensureControlListenerStarted()
    } catch {
      logger.error(
        """
        agent startup advertise failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=await-client-request
        """
      )
    }
  }
```

- [ ] **Step 2: Call it from the composition root**

In `Apps/macOS/Agent/main.swift`, immediately after `agentRuntime.start()` at line 167, add:

```swift
  // Advertise without waiting for a client, because the iPhone browses for the
  // control listener and cannot dial the mach service that would start it.
  Task { await controller.startAdvertising() }
```

Leave the existing `assertRunningConfigMatchesLibrary` task that follows it unchanged.

- [ ] **Step 3: Build and gate**

Run:
```bash
SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile \
SWIFT_MK_REQUIRE_SIGNING=1 SWIFT_MK_SIGN_IDENTITY="Apple Development" \
SWIFT_MK_SIGN_TEAM=H3BMXM4W7H SWIFT_MK_SIGN_STYLE=Automatic \
swift Tools/cell-tunnel-dev.swift build mac Debug
```
Expected: every gate `ok`, exit 0.

- [ ] **Step 4: Verify the agent advertises with no client**

Run:
```bash
launchctl bootout gui/501/io.goodkind.celltunnel-agent 2>/dev/null
rm -rf /tmp/agent-check.app
cp -R Products/Debug/CellTunnelAgent.app /tmp/agent-check.app
open -a /tmp/agent-check.app
sleep 8
dns-sd -t 10 -B _cellrelaycontrol._tcp local > /tmp/advertise-check.txt 2>&1
grep -c 'Add' /tmp/advertise-check.txt
```
Expected: at least one `Add` line, meaning the record is published without any client having sent a request. `dns-sd` without `-t` never terminates over a non-interactive session, so the timeout is required.

- [ ] **Step 5: Verify routing is off after a restart**

Run:
```bash
Products/celltunnelctl status 2>&1 | grep routing_intent
launchctl kickstart -k gui/501/io.goodkind.celltunnel-agent
sleep 5
Products/celltunnelctl status 2>&1 | grep routing_intent
```
Expected: `routing_intent=off` after the restart, whatever it was before. The agent must never turn routing on by itself.

- [ ] **Step 6: Commit**

```bash
git add Apps/macOS/Agent/main.swift Apps/macOS/Agent/AgentTunnelController+Control.swift
git commit -S -m "Advertise at startup instead of waiting to be asked" \
  -m "Only a client request published the record the iPhone browses for, and the iPhone reaches the Mac over the local network rather than the mach service, so it could never send that request." \
  -m "Co-authored-by: Claude <noreply@anthropic.com>"
```

---

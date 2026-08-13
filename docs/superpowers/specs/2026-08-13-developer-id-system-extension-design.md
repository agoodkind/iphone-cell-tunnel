# The Developer ID release ships the tunnel as a system extension

The downloadable Mac app installs to Applications, and on first launch it asks
macOS to activate its bundled tunnel system extension with one Allow prompt.
After that approval, macOS runs the tunnel on its own. Development and CI keep
the app-extension packaging exactly as they are today.

## The measured deadlock this resolves

Run 31650693297 on pull request 113 installed and pinned the Managed DeveloperID
profiles and failed on one thing: the app entitlements request the
app-extension form of the tunnel permission (`packet-tunnel-provider`), and
Developer ID profiles carry only the system-extension form
(`packet-tunnel-provider-systemextension`). Apple issues the app-extension form
only in App Store and development provisioning, and this app never ships
through the App Store. No signing change can bridge that; only the packaging
can.

The July evidence in ICT-20 rules out a shortcut: macOS registers app
extensions from apps in Applications, the agent runs from a harness directory,
and the system logged zero registrations until the harness registered the
extension directly with pluginkit. A system extension has the same anchor
stated by the platform: an app the user launched from Applications must submit
its activation. Today nothing in this product is launched from Applications,
which is exactly what this design changes for the release artifact only.

## Shape

The Mac app (the existing Catalyst front-end) becomes the download artifact.

- The release build packages the tunnel provider as a `.systemextension` inside
  the app bundle's `Contents/Library/SystemExtensions`, signed with the
  Managed DeveloperID profiles and the `-systemextension` entitlement strings.
- On first launch of a Developer ID build, the app submits the
  `OSSystemExtensionManager` activation request and handles the delegate
  outcomes: needs approval, activated, superseded on upgrade, failed with a
  reason. The user clicks Allow once in System Settings.
- The app creates the VPN profile pointing `NETunnelProviderManager` at the
  system-extension provider bundle identifier.
- After activation, macOS owns the provider's lifetime. The agent, the relay,
  and the loopback dial behave as they do today.

## What does not change

- The provider class, WireGuard, RouteGate, and every line of tunnel code.
- The agent's ownership of the config library, routing intent, and the relay
  bridge (the daemon-owns-the-system contract).
- The plain-UDP loopback dial from the Mac extension to the agent, and the
  control plane.
- Development and CI: the app-extension target, the plain entitlements, the
  `TUIST_DISTRIBUTION_SIGNING` CI mode, and the second-Mac harness with its
  pluginkit registration.

One platform-forced exception to the rule that the app has no ability
`celltunnelctl` lacks: only a user-launched app may submit activation, so
submission is app-only. Activation state still publishes through the agent's
snapshot, so `celltunnelctl` reads it like everything else.

## Unknowns the probe kills first

ICT-24 answers these on the tart machine before any repository restructuring,
by wrapping the existing provider binary in a minimal hand-built system
extension inside a throwaway Applications app:

1. The provider, now a root system service, still reaches the agent's loopback
   relay listener.
2. The app-group container and data-protection keychain items the provider
   reads are accessible from the system-extension context.
3. `NETunnelProviderManager` starts a profile pointing at the system-extension
   provider bundle identifier.
4. The Allow prompt is answerable by keyboard in the machine's window, the way
   the second-Mac harness already answers system alerts.

A failed probe stops the epic before it costs anything; the fallback discussion
returns to the owner with the probe's log lines.

## Delivery order

ICT-24 probe, then ICT-25 (the release-only system-extension target bundled
into the app), ICT-26 (the activation flow in the app), ICT-27 (the documented
end-to-end flow run against the notarized release artifact in the machine,
including the upgrade path), ICT-28 (the release pipeline packages and smokes
the app dmg). ICT-20 closes at ICT-28, which unblocks ICT-1.

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

The agent app carries and activates the extension, and it is the download
artifact. macOS requires a system extension's identifier to be prefixed by its
containing app's, and the tunnel provider's identifier is derived from the
agent's, not the Catalyst front-end's. Apple issued the two Developer ID
profiles for exactly that pairing, and the one granting
`com.apple.developer.system-extension.install` is the agent's. The probe
activated this pairing.

- The release build packages the tunnel provider as a `.systemextension` inside
  the app bundle's `Contents/Library/SystemExtensions`, signed with the
  Managed DeveloperID profiles and the `-systemextension` entitlement strings.
  The provider is a new product type rather than a rewrapped app extension: a
  system extension starts from a `main` that calls
  `NEProvider.startSystemExtensionMode()` and declares its provider in a
  `NetworkExtension` dictionary, where an app extension links `NSExtensionMain`
  and declares `NSExtension`. The provider class carries over unchanged.
- Two Info.plist values are load-bearing and both were measured, not assumed:
  the bundle needs `NSSystemExtensionUsageDescription`, and its
  `NEMachServiceName` must be prefixed with an app group from the entitlement,
  not the team identifier.
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
  control plane. The probe proved the dial still lands when the sender is a root
  system service.
- Development and CI: the app-extension target, the plain entitlements, the
  `TUIST_DISTRIBUTION_SIGNING` CI mode, and the second-Mac harness with its
  pluginkit registration.

One platform-forced exception to the rule that the app has no ability
`celltunnelctl` lacks: only a user-launched app may submit activation, so
submission is app-only. Activation state still publishes through the agent's
snapshot, so `celltunnelctl` reads it like everything else.

## What the probe measured

ICT-24 built a minimal provider as a real system extension, signed it with the
Managed DeveloperID profiles, and activated it inside a throwaway app in the
machine's Applications folder. It answers the questions this design rested on.

The extension activates, reaches `activated enabled`, and the system launches
it as root. A profile whose `providerBundleIdentifier` names the system
extension saves, starts, and reports connected. The provider's datagram arrives
at a console-user listener on the agent's loopback relay port, so the relay dial
survives the move to a root system service. The whole approval flow runs from
the keyboard with no attached console.

The probe also measured what the root context isolates, and it costs this
product nothing. The extension's app-group container resolves under `/var/root`
rather than the console user's home, and its standard defaults hold none of the
values a user-level process wrote. Neither matters here: the Mac provider opens
no app-group container and reads no keychain, its config arrives in the provider
configuration, and the relay port it resolves has no writer on macOS, so the
agent and the provider both resolve the same default from empty defaults exactly
as they do today. The isolation is a constraint to respect later, not a change
to make now: a macOS value shared through defaults or the app group would break
under it, which is a reason to keep passing provider inputs through the provider
configuration.

## Delivery order

The ICT-24 probe passed, so the epic proceeds: ICT-25 (the release-only
system-extension target bundled into the app, carrying the relay port in the
provider configuration), ICT-26 (the activation flow in the app), ICT-27 (the
documented end-to-end flow run against the notarized release artifact in the
machine, including the upgrade path), ICT-28 (the release pipeline packages and
smokes the app dmg). ICT-20 closes at ICT-28, which unblocks ICT-1.

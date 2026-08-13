# Running Cell Tunnel today

Running Cell Tunnel takes a build from source, a paid Apple Developer account, and a
second device or machine to act as the phone. There is no download.

This page states what that costs today, so the difference between it and installing an
app is concrete.

## What a person needs before anything runs

A paid Apple Developer account, because the tunnel uses Network Extension entitlements
that a free account cannot carry.

A signing identity and a team, recorded in `Config/local.xcconfig`. The build writes its
signing override only when an identity or a team resolves. With neither, it writes
nothing, and the result is a bundle with no team identifier that launches normally and
fails later, when something first reaches the keychain, as status `-34018`.

A checkout that has generated its configuration constants. Those constants are not
tracked, and the step that generates them compiles a tool that needs them, so a fresh
worktree cannot generate them by itself. `AGENTS.md` holds where those values come from.

## Building

`make build` compiles every platform. Named targets build one platform each, listed in
`README.md`.

Signed products land under `Products/`, not under `build/DerivedData`. The macOS slice
sits in `Products/Debug`, and the others carry a platform suffix.

Confirm a bundle is signed rather than assuming it, because an unsigned one behaves
normally until it reaches the keychain:

```sh
codesign -dv Products/Debug/CellTunnelAgent.app
```

A team identifier means it is signed. `Signature=adhoc` with no team identifier means it
is not.

## Why the release cannot use the system-extension entitlement

Apple's Developer ID provisioning carries the Network Extension entitlement only in
its system-extension form, and this app cannot adopt that form by changing the
entitlement string. The system-extension form belongs to tunnels that ship as system
extensions, which macOS activates only from an app a user launched out of
`/Applications`. This product's tunnel is an app extension hosted inside the
background agent, which nothing launches from `/Applications`; the second-Mac harness
registers the extension directly for exactly that reason. A release build signed with
the system-extension string would therefore carry a tunnel nothing in this product's
install flow can activate.

The mismatch is measured: run 31650693297 on pull request 113 installs the Developer
ID profiles, pins them, and fails because the app-extension entitlement the targets
request does not appear in those profiles. Only App Store and development provisioning
carry the app-extension form.

## Running on your own Mac

`make install-mac` installs the Mac side and `make iphone-install` installs the iPhone
app. `make run-catalyst` opens the Mac app from a built product.

The Mac side runs a background agent that owns the tunnel and the configuration library.
The app and `celltunnelctl` both drive that agent, so either can import a configuration,
choose which one is active, and start or stop routing.

Traffic needs a real iPhone running the app on the same local network, because the phone
is what carries the cellular link.

## Running against a second Mac

One command builds every target signed, installs the products on a second Mac, runs the
agent there, launches the phone app in a simulator, and waits for the two to pair:

```sh
swift Tools/cell-tunnel-dev.swift mac <host> Debug
```

It checks that Mac is ready before it builds anything, and names whatever is missing.
Running it again against the same Mac replaces what it installed.

Builds happen here, not there. What that Mac needs, what it receives, and the approvals a
tunnel cannot start without are in [machine.md](machine.md).

## What still has no command

Granting the three approvals a tunnel needs. Each is a system prompt a person answers.

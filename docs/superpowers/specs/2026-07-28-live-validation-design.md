# Proving the app against a running machine

Validation runs against the app as it stands, before the daemon redesign changes it, so
the findings are real today and become the baseline the redesign must not regress.

Two changes belong to this work rather than the redesign, because the resolver claim
cannot produce a truthful result without them. The tunnel stops inventing a resolver,
and the app gains a section showing the live tunnel's values so a configuration that
did not take effect is visible. Everything else here observes the app rather than
changing it.

## What each item's evidence is

Two claims are about what a person sees, so the app answers them.

A switched-off VPN profile has to name the situation on screen, offer to open System
Settings, and withhold a routing switch that cannot take effect, and it has to reach
that state when the profile is switched off while the app is already running.

The first-run screen has to agree with itself. Its title, subtitle, and button all
describe importing a configuration, and the button presents the file picker.

Four claims are about what the machine did, so `celltunnelctl` answers them, where the
output is exact rather than rendered.

A full-tunnel configuration has to carry every route it names, not a subset, read from
the routing table with that configuration active.

The tunnel has to publish exactly the resolvers the configuration names, and none for
an address family it cannot carry.

Resetting has to clear the active selection and leave the configuration library intact.

The upload and download figures have to name the direction traffic actually moved, on
both the Mac and the phone, measured against traffic sent deliberately in one
direction.

Two claims are already settled from source and are not re-run. Command help text no
longer implies that importing or activating starts the tunnel. Each platform's status
cases are all reachable and no screen switches over a state it cannot enter, though one
shared property still carries three meanings across platforms, which the daemon
redesign resolves rather than validation.

The reset and counter checks run again inside the machine even though the host already
showed them, because the claim is about a running app in a machine.

## The tunnel never invents a resolver

The packet tunnel publishes the resolvers the configuration names and nothing else.
Where it currently substitutes public addresses for a configuration that names none,
that substitution is removed.

Name resolution is not what carries traffic. A full-tunnel configuration with no
resolver still passes packets; only names stop resolving through the tunnel. Choosing a
resolver is the configuration's job, and a client that supplies one on the user's behalf
is deciding where their queries go.

Whether a query then leaves through the tunnel or the physical interface follows from
what the configuration said. The resolver a machine already uses usually sits on a
directly connected subnet, whose route is more specific than a default route, so
queries may still be answered off-tunnel. The matrix below measures that rather than
assuming it.

## The resolver matrix

Six variants, copied from the two real configurations into a gitignored directory, with
neither original edited.

| Routes | Resolvers named | Expected |
| --- | --- | --- |
| Scoped | none | None published, and the machine's own resolver keeps answering |
| Scoped | both families | Exactly those published |
| Full tunnel | both families | Exactly those published, and queries leave through the tunnel |
| Full tunnel | none | None published, and traffic still flows |
| Full tunnel | IPv4 only | Only the IPv4 resolver published |
| Full tunnel | IPv6 only | Only the IPv6 resolver published |

The last three are where an invented resolver would appear, and where publishing for a
family the tunnel cannot carry would send queries out the wrong way.

## Showing the active configuration

The app gains a section listing the live tunnel's values, in the shape a WireGuard
client shows them: addresses, resolvers, maximum transmission unit, and per peer the
endpoint, allowed addresses, keepalive interval, latest handshake, and byte counts.

The section reconciles two truths. The configuration says what was asked for, and the
tunnel holds what took effect. Where they agree, one value appears. Where they differ,
the difference is the point, because a route that failed to install or a resolver that
was not published is exactly the failure the routing and resolver claims exist to
catch.

The daemon performs that comparison and publishes both the values and any mismatch, so
the app renders rather than derives, and `celltunnelctl smoke` emits the mismatch as an
artifact. A disagreement is then catchable without a screen.

## The machine and the phone

The machine runs from storage on an external volume, so the boot volume is untouched
and removing one directory removes everything.

An iPhone simulator boots inside the machine and runs the relay, so the Mac agent and
the phone share one network and each finds the other by browsing. Products build on the
host, because the machine cannot build them, and copy in as signed archives.

## The check that stops a false result

The system loads the packet tunnel extension from the saved profile's provider bundle
identifier, which can resolve to a build other than the one under test, while the agent
runs from wherever its launch agent points. The extension decides every packet-level
behavior, so the two disagreeing produces results that describe the wrong build. This
has already happened once, turning an installed build's behavior into an apparent
defect in current source.

No routing, resolver, or counter result counts until the loaded provider is confirmed to
be the build under test, read from the running process and the path it has open.

## Out of scope

The daemon redesign, which follows this validation and has its own plans. The iPhone's
own screens beyond what the shared snapshot changes. A signed release a person can
download and open, which is a separate piece of work.

# VPN profile state on the Mac

The Mac app tells the user when the saved VPN profile is switched off and offers to open Network settings, rather than presenting a Route traffic switch that cannot take effect. An app cannot switch a VPN profile on for the user, so taking them to the pane is the whole of what it can do.

## What the agent reports

The status snapshot carries the saved profile as one of three states. `absent` means no profile is saved. `disabled` means a profile exists but is switched off. `enabled` means it is ready to carry traffic.

The agent reads the profile fresh on every status request, into its own copy.

Reading a copy matters for two reasons. The agent keeps a cached profile that it also stages changes on while starting the tunnel, and re-reading settings writes every value back onto whichever copy it is given, so re-reading that shared one would discard configuration staged for a save still in flight. Reading also reports success when no profile exists at all, so it cannot distinguish "nothing saved" from "read failed"; a separate copy sidesteps needing that distinction.

Without a fresh read the state would go stale in exactly the case that matters, because the system reports a change to the enabled setting only to a copy re-read from preferences. A read that fails leaves the state unknown, and the app then keeps whatever it last knew rather than assuming the profile is fine. Finding no profile at all also retires the cached copy, which would otherwise keep describing a profile that has been deleted.

`celltunnelctl status` prints the state as `vpn_profile=<state>`.

## Why the enabled flag also gates the not-approved error

A saved profile reports its connection status as invalid in two different situations: the user has never approved it, and the user switched it off. Only an enabled profile that still reads invalid is genuinely unapproved.

Without that distinction the not-approved error would fire for every switched-off profile, and because a failure outranks every other state, the screen would show a generic error with a live routing switch instead of the state that names the problem and carries an action.

## Where the state ranks

The Mac status resolves in order: a failure, then the agent, then the configuration library, then the VPN profile, then the peer and routing.

The library ranks ahead of the profile because deleting every configuration leaves the profile in place. Re-enabling a profile with nothing to route would accomplish nothing, so the app asks for a configuration first. The library check reads the Mac's configuration library, which the Mac reports from the agent's stored configurations rather than from whether a profile exists.

## What the user sees

The switched-off state takes over the whole screen with the guided setup layout. It says the tunnel is switched off in System Settings, lists the two steps that turn it back on, and offers a button that opens System Settings. That layout carries no routing switch, so the app cannot offer a control that would do nothing.

The steps name the row by the same title the system shows, `Cell Tunnel`, and they stay on screen while System Settings is in front, so they are readable at the moment they are followed. They describe only what to do once System Settings is open, because the button covers opening it and the pane it lands on varies.

## How the button finds the pane

The button opens the System Settings pane that lists Network Extension VPN configurations, which is what the tunnel saves.

No pane has a documented way to open it, so that identifier can stop resolving on a future system. Trying alternates would not help: the system reports a refusal only when nothing handles the URL scheme at all, and System Settings claims the scheme whether or not the pane identifier is still valid. A stale identifier therefore reports success and lands the user on some other pane, which is why the steps do not assume which pane opened and name the row to look for instead. A genuine refusal is logged rather than leaving a button that appears to do nothing.

## Verification

A Catalyst UI test drives a fixture that reports a switched-off profile alongside a dialed-in peer and an active configuration, then asserts the screen offers the re-enable action, shows the steps, and shows no routing switch. The peer and configuration matter: without them the switch would be hidden regardless, and the test could not tell the two reasons apart. It needs no live tunnel.

Live confirmation needs one manual pass. Switch the Cell Tunnel VPN off in System Settings while routing is on, confirm the app shows the re-enable screen rather than an inert switch, then switch it back on and confirm the dashboard returns with routing off rather than stuck connecting. Turning routing back on from the dashboard should then carry traffic again.

## What happens to routing while the profile is off

Switching the profile off ends the tunnel session, so the agent drops the routing intent as well.

Dropping it matters because the intent otherwise outlives the session. The tunnel does not restart by itself, so a surviving intent would leave the screen showing a routing switch that reads as connecting, and it would still read that way after the user switched the profile back on. Clearing it means the dashboard comes back with routing off, ready to be turned on again.

The agent acts on the profile reporting itself unavailable, which covers both switching it off and deleting it. A stop the app itself requested clears the intent before the session ends, so this never fires for an ordinary turn-off.

## Known behavior worth naming

Turning routing on writes the profile as enabled, so a user who switches the profile off and then starts routing from the app re-enables it without a separate prompt. Starting routing is an explicit request to carry traffic, and it cannot succeed with the profile off.

# NE extension inbound path investigation

Status: open. This doc holds the question, the confirmed findings, and the test matrix that resolves it.

## Question

Can a process reach the iPhone packet-tunnel extension's listener from the Mac over the USB link, so the data plane survives the iPhone app being closed?

The data plane must run inside the extension, because iOS keeps the extension running in the background while it suspends the app.

## Confirmed findings

Tested on device (iPhone 17 Pro, iOS 26, USB UDID `00008150-000249060A00401C`).

With the extension running and both listeners reporting ready (`phone relay listener ready port=51821` for data, `control listener ready port=51823` for control):

- The kernel drops the Mac's inbound TCP to the control port. Log line: `kernel: tcp drop incoming [...:51823<->...] interface: pdp_ip0 process: CellTunnelPhoneTunnel t_state: LISTEN so_error: 0 reason: NECP`. It repeats on every retry.
- The extension never receives the Mac's inbound UDP to the data port. 2000 datagrams sent over the USB link, zero arrived, no accept logged.
- The extension listener inbox flows bind to `pdp_ip0` (cellular) only.
- The same control connection delivered over usbmux to the device loopback is accepted. The listener code is correct.

"NECP" = Network Extension Control Policy, the in-kernel packet filter that enforces iOS local network privacy.

## What is known and what is not

Apple TN3179 (Understanding local network privacy) states:

- The local-network checks are a packet filter in the NetworkExtension layer, applied to all networking APIs.
- They cover inbound listening and outbound connecting to directly-connected, link-local, multicast, and broadcast addresses.
- The grant is keyed per app by the main executable UUID.
- Root daemons are exempt. Apps and agents are subject.

The USB link is a directly-connected link-local network, so this filter applies to it in both directions.

Two points are not documented by Apple:

- Whether a packet-tunnel provider can hold local-network access at all.
- Whether a host app's grant extends to its extension.

Apple DTS forum threads 123175, 695408, and 718461 confirm there is no public API to bind an `NWListener` to a chosen physical interface and no documented answer for providers.

## Interface-binding API facts

Source: iOS 26 SDK `Network.framework` headers (`parameters.h`, `interface.h`).

- `NWParameters.prohibitedInterfaceTypes: [NWInterface.InterfaceType]?`.
- `NWParameters.requiredInterface: NWInterface?`.
- `NWParameters.requiredInterfaceType: NWInterface.InterfaceType`.
- `NWInterface.InterfaceType` cases: `.other`, `.wifi`, `.cellular`, `.wiredEthernet`, `.loopback`.
- The header docstrings state these apply to "connections or listeners". They affect an `NWListener`'s bound interface.
- A USB CDC-NCM link is expected to report `.wiredEthernet` (high confidence, not yet confirmed on device).
- Runtime interface discovery: `NWPathMonitor`, then `path.availableInterfaces`, each with `.name: String` and `.type: NWInterface.InterfaceType`. Pattern already used in `Apps/PhoneTunnelProvider/Runtime/CellularPathObserver.swift`.

## Test matrix

Each cell is an independent on-device datapoint. No conclusion is drawn from one cell about another. Fill every cell.

Each cell records: pass/fail, the kernel log line (drop or none), and the accept log line (present or absent), for both probe transports (TCP 51823, UDP 51821), with the Local Network permission state noted.

| # | Direction | iPhone peer | iPhone listener interface constraint | Purpose |
|---|---|---|---|---|
| 1 | Mac dials iPhone | host app | none | Baseline. Reproduce the known working case. |
| 2 | Mac dials iPhone | extension | none | The current failing case. NECP drop on `pdp_ip0`. |
| 3 | Mac dials iPhone | extension | `prohibitedInterfaceTypes = [.cellular]` | Negative constraint. Does the drop move or clear. |
| 4 | Mac dials iPhone | extension | `requiredInterface = <USB en-class>` | Positive pin to the USB interface. |
| 5 | iPhone dials Mac | extension dials, Mac listens | not applicable | Provider outbound to a local-network listener. |
| 6 | iPhone dials Mac | host app dials, Mac listens | not applicable | App outbound, for comparison with cell 5. |

Cells 1 and 2 are controls. Cell 5 tests whether the working direction is the reverse of the current one. Cell 5 needs a Mac-side listener in the Mac agent (`Apps/macOS/Agent`), a normal process that can hold the macOS local-network grant.

Open question for cells 3 and 4: whether the iPhone is also on Wi-Fi changes the result, because `prohibitedInterfaceTypes` lets the listener drift to Wi-Fi. Record Wi-Fi on or off for each run.

## How to capture each probe

- iPhone subsystem log: `swift Tools/cell-tunnel-dev.swift iphone-logs --collect --last 5m`.
- Kernel drops: `swift Tools/cell-tunnel-dev.swift iphone-logs --collect --last 5m --predicate 'process == "kernel"'`, looking for `tcp drop incoming ... reason: NECP`.
- Mac log: `log show --predicate 'subsystem == "io.goodkind.celltunnel"' --info --debug --last 5m`.

## Decision rule

The deciding behavior is undocumented, so the topology is chosen by the matrix, not by reading.

A topology is chosen only after its cell passes on device: the extension receives inbound datagrams over the USB link, with no NECP drop on the data path.

## Resolved topology

To be filled when the matrix completes.

If a Mac-dials-iPhone cell passes (3 or 4): keep that direction, apply the minimal interface constraint that passed.

If only cell 5 passes: the iPhone extension dials out over the USB link to a listener in the Mac agent, which pipes datagrams to and from the macOS packet-tunnel extension over the existing app-group and XPC seam.

## Control plane

The control message that gives the iPhone the WireGuard server address runs through the iPhone host app.

The host app holds the local-network grant and runs Bonjour discovery, then forwards the address to the extension via the app group and `NETunnelProviderSession.sendProviderMessage`. The macOS provider already uses this pattern in `handleAppMessage`.

Reconnecting may require reopening the iPhone app.

## Related tickets

- `OSS-64`: confirm the extension listener can receive inbound from the Mac over the local link.
- `OSS-63`: Mac tunnel comes up immediately and retries the relay connection forever without hard-failing.
- `OSS-66`: replace Bonjour-from-extension discovery with fixed-port direct connect.

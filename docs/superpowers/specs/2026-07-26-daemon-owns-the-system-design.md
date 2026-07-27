# The daemon owns the system

The Mac agent runs on its own and decides everything. The app and the command-line
tool read what it publishes and send it commands. Neither derives state, keeps a
second copy, or holds a rule the other does not have.

## Why this changes

Three properties the product needs are absent today.

The agent starts only when a client dials its service, so after a reboot with the
app closed no agent exists and nothing advertises. An iPhone browsing for the Mac
finds nothing, and no amount of waiting helps.

The agent exits sixty seconds after its last request. The only recurring request is
the app's status poll, which stops when that window closes. The tunnel's liveness is
therefore tied to a window being open.

Twelve decisions live in the app rather than the daemon, including both status state
machines, the rule for whether routing may start, peer auto-selection, and the
accumulation of byte totals. The app and the command-line tool consequently disagree
about the same agent, and the byte totals lose everything that moves while the app is
closed.

## Ownership

**The Mac agent** owns the configuration library, the routing intent, peer selection,
the relay bridge and its advertisement, the decision to install or withdraw routes,
byte totals, and which situation each client is showing. It starts at login,
advertises immediately, and runs until the login session ends.

**The iPhone tunnel extension** owns discovery, which Mac to dial, the cellular
forwarder, and its own byte totals.

**The Mac tunnel extension** owns the routes and the resolver. It withdraws them
itself when its connection to the agent drops, so a dead agent cannot leave traffic
pointed at a bridge that no longer exists.

**The app and `celltunnelctl`** own presentation and input. They subscribe to a
snapshot, render it, and send commands. Neither computes anything.

The daemon publishes which situation it is in rather than the words for it. Each
client maps that situation to its own text, the app to a screen and the command-line
tool to a printed line, so wording and translation stay where they belong while the
decision does not.

A change is out of bounds if it gives the app an ability `celltunnelctl` does not
have.

## The interface

**Subscribe.** A client opens one connection and receives a snapshot immediately,
then a new one whenever the state changes. The snapshot is complete: the status word,
what the user should do next, whether each control is available, the byte totals, and
the link list. A client renders it without combining fields.

**Command.** Each user action is one request that either succeeds or returns a reason
the daemon has already phrased. Import a configuration, activate one, turn routing on
or off, choose a peer, reset. No two-request sequences, no client-side undo, and no
timeouts counted by the client.

## Lifetime and recovery

The agent starts at login and keeps running. It stops when the user turns the tunnel
off, or when the login session ends.

If the agent goes away unexpectedly, launchd starts it again. The Mac tunnel
extension notices the dropped connection and withdraws its routes, so traffic falls
back to the physical interface rather than stopping. The app reports that the tunnel
is no longer carrying traffic rather than showing a stale reading.

Routing does not resume by itself. The agent never turns routing on without being
asked, so any restart leaves it off and the user turns it back on. Nothing about the
routing choice is written to disk.

## What moves out of the app

Both status state machines. The rule for whether routing may start, which currently
differs from the agent's and produces a live switch the agent then rejects. The
routing-request timeouts, which are counted in poll ticks and freeze when the app
backgrounds. Throughput and lifetime byte totals. The duplicate peer auto-selection,
which uses different rules than the extension's copy. The two-request transaction
that adds a configuration without changing the active one. The duplicate network
probes and the arbitration between their results and the agent's.

## What is deleted

The per-second status poll, replaced by the subscription. The agent's idle countdown
and the state machine around it. The Mac-side discovery request, whose result nothing
renders. The app's second copy of peer selection.

## How this is proven

Every status word and every availability rule becomes a pure function over the
snapshot, in shared code, with tests. None of them have tests today, and the single
test guarding that boundary asserts that source files contain particular text.

`celltunnelctl` gains a command for each user action, so every flow runs headless.

A live run then confirms what only a real machine shows: that a full-tunnel
configuration carries every route, that a configuration with no DNS line still
publishes a resolver on the tunnel, that the byte counters name the right direction,
and that a switched-off VPN profile is explained rather than silently failing.

## Out of scope

The iPhone's own user interface beyond what the shared snapshot changes. Socket
activation through launchd, which would let the phone start the agent, is not needed
once the agent is resident.

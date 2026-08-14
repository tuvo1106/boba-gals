# ADR-0028: `OrderChannel` rate-limits failed lookups per IP, in Redis, independent of Rack::Attack

- **Status:** Accepted
- **Date:** 2026-08-13
- **Design reference:** DESIGN.md §13.1, §13.2
- **Relates to:** issue #39

## Context

§13.1 authorizes both `GET /orders/:pickup_code` and `OrderChannel#subscribed` with the
pickup code alone — a 4-character token from a 30-character unambiguous alphabet, ≈810k
codes per store per day. §13.2 throttles the REST endpoint at 60/min per IP via
Rack::Attack, and the surface map calls that throttle the reason "enumeration isn't worth
anyone's time."

That reasoning doesn't extend to the channel. Rack::Attack instruments the Rack middleware
stack, so it sees the `/cable` upgrade as one HTTP request and nothing after — every
`subscribe` command on an already-open connection is invisible to it. §13.2 shipped
(PR #78) without covering this, exactly as issue #39 predicted: implementing the table
verbatim leaves the cheaper of the two doors unthrottled. A single websocket connection can
retry an unbounded number of pickup codes at whatever rate the client can send frames,
independent of the REST throttle entirely.

## Decision

`OrderChannel#subscribed` checks `ThrottleOrderLookups.exceeded?(remote_ip)` before doing
the lookup, and records a failure (`ThrottleOrderLookups.record_failure`) only when the
lookup comes back empty. The budget is 60 failures per minute per IP — the same number as
`status/ip`, so guessing costs the same whether it happens over REST or the channel.

Two choices worth calling out:

- **Keyed by IP in Redis, not by connection.** A per-connection counter is defeated by
  opening a new connection per batch of guesses — cheap for an attacker, and the initial
  `/cable` upgrade *is* visible to Rack::Attack but nothing stops a client from making many
  of them. Redis is already how every other cross-pod counter in this app works
  (`ThrottledBroadcast`, the rate limiter's own store) for the same reason: `web` runs 2
  pods (§14.2), and an in-process counter would hand each pod its own independent budget.
- **Counts failures, not attempts.** A customer who reconnects mid-wait (a phone screen
  lock, a flaky connection) resubscribes with the same, valid code and should never spend
  the budget meant for someone guessing. This does mean an attacker who happens to guess
  right pays nothing for that one success — acceptable, since a correct guess is exactly the
  outcome the budget exists to make rare, not something to penalize further once it happens.

`ApplicationCable::Connection` gained a public `remote_ip` method that wraps the private
`request.remote_ip` — `request` is private on `ActionCable::Connection::Base`, callable
inside `Connection` via implicit `self` but not from a channel's `connection.request`. This
was caught by hand-verifying against a running dev server, not by the spec suite: RSpec's
`ActionCable::Channel::TestCase::ConnectionStub` defines whatever singleton method a test
stubs, so `stub_connection(request: instance_double(...))` passed happily against a method
the real connection object cannot expose the same way.

## Alternatives considered

| Option | Why not |
|---|---|
| Reject after N failures on the connection object itself (no Redis) | Defeated by opening a new connection per batch of guesses. `web` running 2 pods also means an in-process counter on the connection undercounts nothing here (one connection is pinned to one pod) — but it still can't stop the multi-connection version of the same attack, which is the one that actually matters against an 810k-code space. |
| Route the check through Rack::Attack itself | Rack::Attack throttles are keyed to Rack requests; `subscribe` is an ActionCable protocol message with no Rack request behind it. Would need a second, parallel throttling mechanism inside the gem or a hand-rolled Redis check anyway — this is that check, without the extra indirection. |
| Lower Rack::Attack's `status/ip` limit to compensate | Does nothing — the channel bypasses that throttle entirely, so tightening it only makes the REST endpoint more restrictive without touching the actual gap. |
| Count every subscribe attempt, not just failures | Simpler, but throttles legitimate reconnects on shared/NAT'd IPs (a food court, a campus network) using the same budget as someone enumerating codes, for no security benefit — a successful lookup was never the thing being guarded against. |

## Consequences

The channel and the REST endpoint now cost an attacker the same per IP, closing the gap
issue #39 identified. §13.2's table in DESIGN.md still shows only the three Rack::Attack
throttles — updating it to mention this fourth, differently-implemented one is a DESIGN.md
edit and belongs in its own PR per this repo's rule, not folded into this change.

A shared IP (campus Wi-Fi, a food court) now has one 60-failure budget across every
customer behind it for the channel, same as it already did for the REST endpoint — not a
new tradeoff, just extended to the second door.

## Revisit when

If `OrderChannel` ever gains a real identity (a logged-in customer account, say), the
budget should probably move from per-IP to per-identity, the same shift the REST throttle
would face if the same feature landed there.

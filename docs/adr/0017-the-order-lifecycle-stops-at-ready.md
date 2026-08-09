# ADR-0017: The order lifecycle stops at `ready`, and views bound themselves

- **Status:** Accepted
- **Date:** 2026-08-09
- **Design reference:** DESIGN.md §5.1, §9.2, §9.5
- **Related:** ADR-0005 (pickup is not tracked)

## Context

`RollUpOrderStatus` is the only writer of `orders.status`, and it produces exactly four
values: `placed`, `in_progress`, `partially_ready`, `ready`. None of §5.1's three terminal
states is reachable:

- `picked_up` — deliberately unobserved (ADR-0005). A counter-service shop has no natural
  handoff moment, and §9.4's KDS has nowhere to tap because finished drinks leave the lane.
- `abandoned` — needs §5.1's recurring sweep, which was never built.
- `cancelled` — there is no cancellation path in the application at all.

So `Order.open`, defined as "not terminal", currently means **"ever placed"**. It grows by
one row per order sold and never shrinks. On the dev store: 33 orders placed, 27 "open", the
oldest sitting `ready` since the previous day.

The obvious fix is §5.1's sweep. Measuring first showed it would be solving the wrong
problem. Cost of the three hot reads against the number of open orders, on the compose
stack:

| open orders | `ProjectEta.for_open_orders` | `BoardView.call` | `OrderBroadcast.publish` |
|---|---|---|---|
| 27 | 30ms | 5ms | 13ms |
| 527 | 23ms | 5ms | 108ms |
| 2027 | 12ms | 3ms | 371ms |

`ProjectEta` and `SchedulerStateStore` are flat because they filter on **item** status
(`queued` / `in_progress`) and merely `.merge(Order.open)` on top; a collected order's items
are all `finished`, so it is excluded by the item filter regardless. `BoardView` is flat
because it already bounds itself in SQL (`READY_BOARD_TTL`, `PICKED_UP_PERSISTENCE`).

Exactly one caller iterated open orders directly, and it was the only one that grew.

## Decision

**Do not build the sweep. Do not introduce a terminal state nothing can honestly set.** The
order lifecycle ends at `ready` for now, and §5.1's `picked_up` / `abandoned` / `cancelled`
stay unreached.

**Views bound themselves in the query.** `Order.live` selects orders with work outstanding,
plus orders that went `ready` within `LIVE_AFTER_READY` (5 minutes, matching
`BoardView::READY_BOARD_TTL` — the same event from two sides of the counter).
`OrderBroadcast` uses it. The window is safe to keep short because `ready` is the last
transition there will ever be: once delivered, there is nothing further to push, and a
customer reloading `/order/<code>` still gets the truth from REST.

Measured after: 2027 open orders, 8 live, **15.5ms** per publish.

## Alternatives considered

| Option | Why not |
|---|---|
| §5.1's abandoned sweep | Stamps `abandoned` on every order a customer happily collected, because pickup is unobserved (ADR-0005). Invents data, and makes any future abandonment metric read 100%. |
| Sweep to `picked_up` instead | Same fabrication, opposite direction — asserts collection we did not see. |
| Add `ready` to `TERMINAL_STATUSES` | Breaks the feature: `OrderBroadcast` would exclude the order at the exact moment it needs to deliver "ready" to the customer watching. |
| Leave it alone | The fanout is linear and unbounded — 371ms per publish at 2000 orders, up to once a second, growing forever. |

## Consequences

The bound holds by construction rather than by a job running. That matters more than it
sounds: #40 measured trailing flushes landing ~7 seconds late, and a sweep that silently
stops leaves the set unbounded again with no signal.

`Order.open` survives, still means "ever placed", and is now documented as such on the model
so nobody reads it as "still being worked on". Its two remaining callers are unaffected —
they were never really using it.

What is given up: nothing operationally, and an honest record that the shop does not know
whether a drink was collected. That was already true; this stops the codebase implying
otherwise.

## Revisit when

A pickup signal actually exists — a POS that settles at collection, lockers, a dedicated
expo screen. At that point `picked_up` becomes observable, §5.1's sweep becomes meaningful
for the genuinely uncollected, and the abandonment rate becomes a number worth reporting.
Until then, do not infer it.

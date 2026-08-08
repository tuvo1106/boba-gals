# ADR-0015: The projection seeds drinks already being made, and NaiveEta retires

- **Status:** Accepted
- **Date:** 2026-08-08
- **Design reference:** DESIGN.md §6.5, §7.1, §9.5
- **Supersedes:** ADR-0004

## Context

§7.1 specifies the forward projection as: *"Assign queued items to the next-free station."* Taken
literally that is incomplete, and the gap is customer-facing.

The scheduler's flow set is built from `order_items WHERE status = 'queued'` (§6.5) — a drink
being made right now is not in it, because it is no longer waiting to be dispatched. So an
order whose every drink is already in progress produces no projection entry at all, and
`BoardView` falls back to `estimates.fetch(order.id, 0)`.

The board then shows **0 seconds for a drink a barista is still pouring**. Caught by curling
the compose stack, not by the suite: every spec had queued work alongside the in-progress
drink, so the order always appeared through its queued items.

`NaiveEta` did not have this problem — it summed `OrderItem.active`, which is
`queued` *and* `in_progress`.

## Decision

The projection seeds `@item_projection` with in-progress drinks before running the dispatch
loop, at `ready_at = max(started_at + prep_seconds, now)`. They then flow through §7.1's
"order ETA = max over its items" unchanged.

The `max(…, now)` matters: a drink that has overrun its estimate is nearly done, not overdue
by however long it has been running. Projecting its finish in the past would let the loop
dispatch before `now` and quote negative waits.

**`NaiveEta` is deleted** rather than kept as a fallback. It has no callers left, and a second
estimator that disagrees with the first is a bug waiting for someone to compare them.

## Consequences

**One customer-visible behaviour change, and it is a correction.** ADR-0004 chose the
cumulative-FIFO reading of `total_work / stations` so that the tenth order read differently
from the first. A consequence nobody noticed: with three idle stations, the *second* customer
of the day was quoted longer than the first, because their drink was added to a cumulative
total rather than assigned to an idle barista. The projection assigns it to a free station and
quotes the same number. That is correct, and it invalidated a spec asserting the old
behaviour — rewritten to assert the property that actually holds (the estimate grows once
every station is busy), plus a new one pinning the idle-capacity case.

**`CreateOrder` now reads Redis inside its transaction**, via `SchedulerStateStore#load`
fetching live deficits. §8 bans broadcasts, jobs and HTTP calls inside a transaction; this is
none of those. It is a read with nothing to roll back, and the alternative — projecting from
zeroed deficits — would quote from a queue state the scheduler is not in.

**The projection must never call `SchedulerStateStore#save`.** `pick_next` mutates what it is
given: drawing down deficits, advancing the ring pointer, shifting items off flow queues
(§6.2). Persisting that would mean quoting a customer an ETA silently consumed the real
queue's deficits and reordered what the kitchen makes next. A spec asserts the Redis keys are
byte-identical across a projection — and its first version passed vacuously, globbing
`sched:*` when `BobaGals.redis_key` namespaces every key by environment, so it compared an
empty hash against an empty hash. Both the glob and the fixture were fixed; the fixture now
uses prep times that leave a real deficit remainder, because six 60s drinks against a 120s
quantum round-trip to zero and would have passed for the wrong reason too.

## Alternatives considered

**Have `BoardView` add in-progress time itself.** Keeps the projection purely about queued
work. Rejected: it puts half the ETA calculation in the view, and §9.5's "Next up" section
plus §7.2's broadcast would each need their own copy of the same arithmetic.

**Include in-progress items in the scheduler's flow set.** Fixes it at the source, and wrong:
`pick_next` would then be able to dispatch a drink that is already being made. §6.5's flow set
is queued-only for a reason.

**Keep `NaiveEta` as a fallback for when the projection is slow.** Speculative — nothing has
measured the projection as slow, and it is bounded by the queue depth. Two estimators that can
disagree is a worse problem than one that might need optimising.

# ADR-0004: The naive board ETA is cumulative FIFO work, not a flat store average

- **Status:** Accepted
- **Date:** 2026-08-07
- **Design reference:** DESIGN.md §12 (build step 3), §7.1 (forward projection), §6.2 (backward scheduling)

## Context

Build step 3 says the board ships with a naive ETA: `total_work / stations`. Step 7 replaces
it with the §7.1 forward projection, which runs the real scheduler against the current queue.

`total_work / stations` has two readings, and the difference is not cosmetic:

1. **Flat.** All outstanding prep seconds divided by active stations. Every order on the
   board shows the same number.
2. **Cumulative.** For each order, the work ahead of its last drink plus its own, divided by
   active stations. Orders show increasing numbers down the queue.

Reading (1) is what the sentence literally says. It is also unusable: a board where the
order about to be called and the order placed nine minutes later both read "12 min" is worse
than no board, because it is confidently wrong rather than absent. The number's entire
purpose is to distinguish "you're next" from "go sit down".

A third option was considered and rejected: greedy list scheduling — walk the queue
assigning drinks to the next free station, yielding per-item `projected_ready_at`. That is
materially more accurate. It is also 80% of §7.1's implementation, which would mean building
step 7's machinery at step 3 while the thing it is supposed to project — the scheduler —
does not exist yet. The design's sequencing is deliberate: naive first, so there is a
baseline to measure the projection against (§10.4 tracks ETA error and bias as first-class
metrics, and a baseline is what makes those numbers mean anything).

## Decision

**Cumulative FIFO work, divided by active stations, times `eta_safety_factor`.**

- Walk the store's active drinks in `queued_at, id` order, accumulating `prep_seconds`.
- An order's estimate is the running total at its last drink — the same "max over its items"
  rule §7.1 keeps.
- Multiply by `eta_safety_factor` (§6.6, default 1.15). §7.1 applies it to the projection;
  applying it here too keeps the quote at ordering time and the board computed the same way,
  which is what makes the step 7 comparison a fair one.
- Capacity is `stations WHERE active`, floored at 1 (§4.1).

**Order-ahead orders are excluded from the queue total and estimated from their promise.**
An order promised further out than its own work plus `promise_buffer` is not work the store
is doing yet. Including it inflates every other row on the board — a 15-drink catering order
promised for 2pm would add eight minutes to everyone standing at the counter at noon. Their
own estimate is `promised_at - now`, because anything derived from queue position would be
a smaller number than the time they were told to come back.

This is a naive reading of §6.2's backward scheduling, applied to one order in isolation.
Step 5 replaces it with the scheduler's `eligible?`, which reasons about the whole queue.

## Consequences

**The number is chunky.** In-progress drinks count their full `prep_seconds` — no credit for
elapsed time — so an order's estimate holds steady and then drops in steps as drinks finish
rather than counting down smoothly. At the minute granularity §9.5 mandates, and with
"Almost ready" absorbing everything under two minutes, this is mostly invisible. It is also
exactly the kind of drift §7.1 exists to remove, so it is not worth patching here.

**It will read low under load.** FIFO cumulative work assumes perfect station packing and no
idle time. Real stations idle. The safety factor covers some of this and not all of it;
§10.4's bias metric is where that shows up once the simulator lands.

**It gets less right, not more, as the scheduler arrives.** DRR (§6.1) deliberately reorders
work, so at build step 5 the queue position this reads from stops predicting dispatch order.
That is the trigger for step 7, and the reason step 7 is sequenced immediately after the
simulator rather than left to drift.

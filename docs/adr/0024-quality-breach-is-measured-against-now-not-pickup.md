# ADR-0024: Live quality breach is measured against `now`, not `picked_up_at`

- **Status:** Accepted
- **Date:** 2026-08-13
- **Design reference:** DESIGN.md §9.4, §9.6, §15
- **Relates to:** ADR-0005

## Context

§9.6 specifies the quality timer: "Starts when a drink reaches `finished`. Measures
`now - finished_at` until `picked_up_at`. Per-drink breach when sitting time exceeds
`quality_limit_seconds`. Logged to `scheduler_events` as `quality_breach`. On the KDS, a
breached order shows a marker."

Build step 8 shipped remakes, offline handling, and SMS, but never this. `quality_breach` sat
in `ScheduleEvent::EVENT_TYPES` and `quality_limit_seconds` sat in `Store::SCHEDULER_DEFAULTS`,
both unused — the only place a breach was ever computed was the simulator
(`app/simulator/simulator/metrics.rb`), which can do it because it generates a pickup delay
per §10.3. Production has no such signal: ADR-0005 decided **pickup is not tracked live** —
no endpoint, no service writes `picked_up_at`. So "until `picked_up_at`" describes a stopping
condition that live code can never observe.

The gap surfaced while wiring the Prometheus quality-breach counter (§15): there was no event
to count.

## Decision

Measure sitting time against `Time.current` instead of a pickup event, and **only while the
drink's order is still `partially_ready`** — waiting on at least one sibling. A barista does
not hand over half an order, so a finished drink whose order has not yet reached `ready`
cannot have been collected: "still sitting" is a fact there, not a guess.

Once every drink in an order finishes and the order reaches `ready`, this stops checking it.
At that point whether it's still sitting or already gone is unknowable without a pickup
signal, and kiosk/web pickup delays (§10.3, means of 100s/180s) are usually well under the
300s default limit — flagging a `ready` order would mostly measure how fast people walk up,
not how long a drink actually sat. That was the first cut of this decision, caught before
merge: scoping to *any* finished drink past the limit, regardless of order status, flags a
real chunk of orders that were collected fine (rough tail estimate off the exponential model:
~5% kiosk, ~19% web) alongside the genuine melted-first-drink cases, with no way to tell them
apart after the fact. Narrowing to `partially_ready` trades recall for precision: it misses
every single-drink order entirely (which never passes through `partially_ready` — it goes
straight from `in_progress` to `ready`) and any multi-drink order whose last sibling finishes
before the sweep catches the earlier breach, but everything it does flag is real.

This also matches language already in the codebase: the dashboard's own hint text calls a lone
drink's wait "just the customer walking over, which no schedule can improve" — the single-drink
case was never this feature's target.

A periodic sweep (`SweepQualityBreachesJob`, `sidekiq-cron`, 30s — the same cadence as the
§7.2 ETA idle tick, for the same reason: nothing else fires while a finished drink just sits
there) finds `finished` items in a `partially_ready` order, older than the threshold, with no
prior `quality_breach` event for that item, and logs exactly one. The existing
`scheduler_events` row *is* the "already flagged" check — no new column, no separate state to
keep in sync with the audit trail that already exists for this.

**The KDS marker rides on a still-visible sibling, not the breached drink itself.** A fully
`finished` order already has no KDS row at all (ADR-0005) — the breach is discovered exactly
when the drink that earned it has already left the queue. §9.6 itself points at why this is
still useful: "multi-drink orders are the main source: the first drink sits while the last is
made." The marker warns the barista finishing that last drink, which is the moment a
proactive remake or a check-in is still possible.

## Alternatives considered

| Option | Why not |
|---|---|
| Track `picked_up_at` live, then measure to it as specified | ADR-0005 rejected this for the whole app — no handoff surface, no dedicated expo person, little depends on it. Reopening it for one metric contradicts a decision already made and re-litigated there, not here. |
| Flag any finished drink past the limit, regardless of order status | The first cut of this decision. Correct while the order is still assembling, noisy once it's `ready` — no way to tell a genuinely forgotten drink from one collected in the last 5 minutes, and pickup delays being usually shorter than the limit makes that noise the majority case for `ready` orders, not the exception. |
| A `quality_breached` boolean column on `order_items` | Duplicates what `scheduler_events` already records. The event log is append-only and already the source of truth for "did this happen"; a column just adds a second thing that could drift from it. |
| Compute the marker live from `finished_at` + threshold, no sweep, no logged event | Cheaper per read, but nothing would ever repaint the KDS when a drink crosses the threshold — broadcasts only fire on drink transitions (§9.2), and a drink sitting quietly finished causes none. The board would show the marker only by coincidence, whenever the next unrelated transition happened to redraw it. |
| Fold the check into the existing ETA idle tick rather than a second job | Different failure domains and different consumers — one recomputes ETAs and publishes to the board and order screens, the other logs an audit event and repaints the KDS. Merging them means an ETA-only bug taking the breach check down with it, and vice versa. |

## Consequences

Production gets a `quality_breach` signal for the first time, but it is **not** the same
quantity as the simulator's `quality_breach_rate` (§10.4), and should not be compared to it or
promoted to it directly. The simulator counts every drink that sat past the limit, measured to
an actual generated pickup (§10.3); this counts only the subset caught while a sibling was
still being made. It undercounts the true live rate on purpose — every drink it flags is real,
but real breaches on single-drink orders and on drinks whose last sibling finished first are
invisible to it entirely. Framed as an operational signal rather than a research metric: it
answers "is the melted-first-drink problem happening right now", not "what fraction of drinks
go stale."

The flat 300s threshold is also blunter than it looks once read against ADR-0014's own spread
figures: p90 spread for 3+ drink orders runs 943s–7505s, 3x–25x past the limit, so the marker
is close to guaranteed on any order that size rather than catching an actual outlier. Left as
is here — it still does §9.6's one job — with size-aware calibration tracked separately
([#80](https://github.com/tuvo1106/boba-gals/issues/80)) rather than blocking this change.

30s sweep granularity means a breach is logged and the marker appears up to 30 seconds after
the drink actually crossed the threshold — imperceptible against a 300s default limit, same
tradeoff the ETA idle tick already accepted.

## Revisit when

A real pickup signal exists (a KDS handoff section, or a POS that settles at collection) —
ADR-0005 already names this trigger. When it does, the live quality timer should switch to
measuring against it and drop the `partially_ready` restriction, which brings the live rate
onto the same definition as the simulator's for the first time and makes the marker clearable,
so it's noticeable the moment the order was actually collected.

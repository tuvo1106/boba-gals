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

Measure sitting time against `Time.current` instead of a pickup event. A drink still
`finished` `quality_limit_seconds` or more ago has gone stale whether or not someone collected
it in the meantime — the live half of the timer answers "has this drink been sitting too
long", and unlike the simulator it cannot also answer "did it stop sitting when the customer
walked up", because nothing tells it that.

A periodic sweep (`SweepQualityBreachesJob`, `sidekiq-cron`, 30s — the same cadence as the
§7.2 ETA idle tick, for the same reason: nothing else fires while a finished drink just sits
there) finds `finished` items older than the threshold with no prior `quality_breach` event
for that item, and logs exactly one. The existing `scheduler_events` row *is* the "already
flagged" check — no new column, no separate state to keep in sync with the audit trail that
already exists for this.

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
| A `quality_breached` boolean column on `order_items` | Duplicates what `scheduler_events` already records. The event log is append-only and already the source of truth for "did this happen"; a column just adds a second thing that could drift from it. |
| Compute the marker live from `finished_at` + threshold, no sweep, no logged event | Cheaper per read, but nothing would ever repaint the KDS when a drink crosses the threshold — broadcasts only fire on drink transitions (§9.2), and a drink sitting quietly finished causes none. The board would show the marker only by coincidence, whenever the next unrelated transition happened to redraw it. |
| Fold the check into the existing ETA idle tick rather than a second job | Different failure domains and different consumers — one recomputes ETAs and publishes to the board and order screens, the other logs an audit event and repaints the KDS. Merging them means an ETA-only bug taking the breach check down with it, and vice versa. |

## Consequences

`quality_breach_rate` (§10.4) goes from a simulator-only metric to one with a live production
analogue for the first time, closing the gap §15 needs to emit it as a counter.

The live rate is not directly comparable to the simulator's: the simulator's is measured to an
actual pickup delay per §10.3, and this one is a lower bound — a drink flagged here was stale
for at least `quality_limit_seconds`, but a drink collected quickly after finishing never
breaches at all, matching what the simulator would also report for it. Both answer "how often
does a drink sit too long", from different denominators the same way ADR-0005 already flagged.

30s sweep granularity means a breach is logged and the marker appears up to 30 seconds after
the drink actually crossed the threshold — imperceptible against a 300s default limit, same
tradeoff the ETA idle tick already accepted.

## Revisit when

A real pickup signal exists (a KDS handoff section, or a POS that settles at collection) —
ADR-0005 already names this trigger. When it does, the live quality timer should switch to
measuring against it, which brings the live and simulated rates onto the same definition and
makes the marker clearable, so it's noticeable the moment the order was actually collected.

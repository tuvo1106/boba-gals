# ADR-0032: Cohesion, re-triggered on sitting time, still ships disabled

- **Status:** Accepted
- **Date:** 2026-08-14
- **Design reference:** DESIGN.md §6.2, §6.4, §9.6, §10.4
- **Relates to:** ADR-0014, ADR-0011, ADR-0019

## Context

ADR-0014 disabled the cohesion boost after measuring its `fraction_made >= 0.5` trigger make
`cohesion_spread` (`ready_at − first_ready_at`) monotonically worse at every load and order
size, and named the fix without attempting it: "A boost keyed on `now − first_ready_at`
would aim at the real thing and could reuse the aging machinery, which demonstrably works.
Untested." Issue #31 is that attempt.

**Implementation.** `Scheduler::Flow` gained a `first_ready_at` field, threaded through both
real callers that already had the value in scope (`SchedulerStateStore`, and the simulator's
`Simulator#rebuild_state` / `Simulator::Projection#fresh_state` — the latter two previously
computed `first_ready_at` for the `cohesion_spread` metric but never fed it back into the
`Flow` the scheduler actually dispatches against, so the simulator could not have measured a
first-ready-at-based trigger correctly even before this change). The trigger itself is now
shaped exactly like aging rather than like the issue's own illustrative snippet, which would
have required `Scheduler::Config` to read `quality_limit_seconds` — a boundary that class's
own header comment forbids ("the scheduler must not grow opinions about" the quality timer's
config). Aging has no normalizing denominator at all: `multiplier += config.aging_rate *
waited_minutes`, unbounded and additive. Cohesion now reads the same way:

```ruby
if config.cohesion_enabled && flow.total_items > 1 && flow.first_ready_at
  sitting_minutes = [ (now - flow.first_ready_at) / 60.0, 0 ].max
  multiplier += config.cohesion_boost * sitting_minutes
end
```

`cohesion_boost`'s meaning changes accordingly, from a fixed bonus applied once past a
fraction-made threshold to a per-minute rate — the same kind of quantity `aging_rate`
already is. `Config::COHESION_THRESHOLD` and `Flow#fraction_made` are removed as dead code.

## The experiment

No new permanent simulator class — `POST /admin/simulations` (and the `Simulator::Scenario`
underneath it) already accepted everything this needed, the same way it already accepted
everything ADR-0014's original sweep needed. Run via an uncommitted `bin/rails runner`
script, pooling 20 seeds per point with the same common-random-numbers pattern
`Simulator::QuantumSweep` uses (identical `seed + day` across every swept value, valid as a
controlled comparison per ADR-0011), at 3 stations.

**`cohesion_spread` p90 by size class** (seconds; `boost_rate` is per-minute):

| demand | rate | 1-2 | 3-6 | 7+ |
|---|---|---|---|---|
| ×1.0 | 0.0 (off) | 39.3 | 204.6 | 779.3 |
| ×1.0 | 0.5 | 40.1 | 205.7 | 736.2 |
| ×2.0 | 0.0 (off) | 82.9 | 1145.7 | 3814.7 |
| ×2.0 | 0.15 | 75.6 | 1133.9 | 3177.9 |
| ×2.0 | 0.5 | 73.2 | 1153.0 | 2367.1 |
| ×2.6 | 0.0 (off) | 59.0 | 2534.8 | 7286.0 |
| ×2.6 | 0.15 | 58.4 | 2392.7 | 6028.3 |
| ×2.6 | 0.5 | 57.3 | 2240.1 | 5011.2 |

At ×1.0 the effect is noise — light load means little queue contention for cohesion to
redistribute. At ×2.0 and ×2.6, unlike ADR-0014's original trigger, **`cohesion_spread`
never gets worse** at any size class across the swept range, and the 7+ class — the one §6.4
opens with — improves substantially: 3814.7s → 2367.1s at ×2.0 (−38%), 7286.0s → 5011.2s at
×2.6 (−31%). `quality_breach_rate_multi` moves the same direction: 0.414 → 0.389 at ×2.0,
0.399 → 0.369 at ×2.6 (rate 0.3, 20 seeds, both demand levels).

**But the improvement is not free.** The same runs, full metrics at rate 0.0 vs. 0.3:

| demand | rate | wait p50 | wait p90 | wait p99 | reneged | breach rate | breach rate (multi) |
|---|---|---|---|---|---|---|---|
| ×2.0 | 0.0 | 293.5s | 1158.9s | 5673.1s | 637 | 0.315 | 0.414 |
| ×2.0 | 0.3 | 320.7s | 1269.4s | 5590.0s | 687 | 0.298 | 0.389 |
| ×2.6 | 0.0 | 718.9s | 2757.3s | 8106.8s | 2818 | 0.300 | 0.399 |
| ×2.6 | 0.3 | 741.0s | 2557.8s | 7804.7s | 2847 | 0.279 | 0.369 |

Median wait gets worse at both loaded conditions (+9.3% at ×2.0, +3.1% at ×2.6), and
reneging increases (+7.9% at ×2.0, +1.0% at ×2.6) — §10.3's own framing is that reneging
"prices the cost of slowness in lost revenue," so this is a real cost, not an abstract one.
p90/p99 wait improve at ×2.6, which reads as the same redistribution showing up on the tail:
quantum taken from typical orders (worse p50, more reneging) is spent on orders whose first
drink is sitting, which happen to correlate with the same large orders that drive the worst
of the p90/p99 tail.

## Decision

**The diagnosis in ADR-0014 was right, and the fix worked as targeted — this is not the
same failure wearing a different trigger.** `cohesion_spread` no longer gets worse anywhere
in the swept range; at load it clearly improves, most for the large orders that motivated
§6.4 in the first place. That is a genuinely different result from "there is no regime in
which it helps."

**`cohesion_enabled` still defaults to `false`.** The barista time the boost spends still
has to come from somewhere, and here it comes from typical orders' median wait and, at ×2.0,
a real increase in reneging. Trading a spread metric for slower typical service and more
lost sales is not obviously the right trade for a shop to make by default, and nothing in
this sweep establishes that the size classes doing better outweigh, in revenue or in
customer experience, the size classes and customers doing worse. That is a judgment call
about the shop's priorities, not a number the simulator produces — recorded here rather than
decided here.

The corrected trigger ships anyway. It is strictly better-justified than the old one, the
mechanism is real (the improvement direction reverses cleanly from ADR-0014's), and a reader
five ADRs from now should see that cohesion was retried with the right quantity, given a
real trial, and found to be a genuine trade rather than left as an untested guess.

## Alternatives considered

| Option | Why not |
|---|---|
| Enable by default at a rate in the swept range (e.g. 0.15) | The spread/breach-rate improvement is real, but so is the median-wait and reneging cost. Flipping a shipped default on a metric-by-metric read, without a stated priority for which metrics matter more, substitutes the simulator's numbers for a judgment only Tu can make. |
| A new permanent `Simulator::CohesionSweep` class + admin endpoint + dashboard chart | ADR-0014's own sweep was reproducible from the existing `POST /admin/simulations` endpoint without any dedicated infrastructure; this one needed nothing more either. Permanent sweep infrastructure for a single research question already answered is maintenance surface with no forecasted reuse. |
| Use the issue's literal suggested formula (`sitting / config.quality_limit_seconds`) | Requires `Scheduler::Config` to read a key its own header comment says the scheduler must not grow opinions about. The aging-shaped rate formula reaches the same kind of quantity without crossing that boundary. |
| Declare success on `cohesion_spread` alone and stop there | §10.4 explicitly warns against reading one metric in isolation — "never the mean" exists for the same reason "never one metric" does here. The wait/renege sanity check is what turned a clean-looking win into an honest trade. |

## Consequences

Every store keeps today's dispatch behavior; nothing changes for a real shop by this ADR
alone. The knob and the corrected mechanism are available for a store or a future ADR to
enable deliberately, with the tradeoff above stated plainly rather than assumed away.

`cohesion_boost`'s numeric meaning changed (fixed bonus → per-minute rate) even though its
shipped default value and disabled status did not. Anyone reading `Store::SCHEDULER_DEFAULTS`
or `Scheduler::Config::DEFAULTS` and assuming `cohesion_boost: 1.0` still means "a modest,
bounded bump once triggered" would be wrong — it now means "1.0 additional quantum per
minute the first drink sits," which is far more aggressive than the old semantics at the
same numeric value. Nothing production-facing is exposed to this today since the feature
ships disabled, but the value itself is stale relative to the swept range (0–0.5) and should
not be read as a considered recommendation.

## Revisit when

Tu (or a future owner) decides which metrics matter more for this specific shop — spread and
breach rate on large orders, versus median wait and reneging on typical ones — and picks a
rate accordingly, or a finer sweep (between 0 and 0.15, where the curve above is steepest
for 7+ orders and gentlest for reneging) narrows the trade further. Until then this is a
real, available option, not a default.

# ADR-0035: The spread learner samples only what the sweep judges

- **Status:** Accepted
- **Date:** 2026-08-14
- **Design reference:** DESIGN.md §9.6, §10.3
- **Relates to:** ADR-0024, ADR-0031

## Context

ADR-0031 replaced §9.6's flat `quality_limit_seconds` with a per-size-class threshold learned
from each order's `ready_at − first_ready_at` spread. It shipped this morning. It contained a
bug that reintroduced the exact failure it was written to fix, from the opposite direction.

`RecordQualitySpread` sampled **every** order that reached `ready`, including single-drink
ones. A single-drink order's spread is not merely small, it is *definitionally zero*:
`RollUpOrderStatus#apply` stamps `first_ready_at` and `ready_at` in the same call when the
only drink finishes. §10.3's size mix is about 62% single-drink, so those zeros dominate the
`"1-2"` bucket that 1- and 2-drink orders share.

Reproduced before fixing: after `MINIMUM_SAMPLES` (10) solo orders, the `"1-2"` stat is
`confident?` with an EWMA of **4.8e-06** and near-zero variance, so `threshold_seconds`
collapses to microseconds. `SweepQualityBreaches#limit_for` prefers that learned value over
the sane seeded `0.5 × 300s`, and `overdue?` is then true the instant a pair's first drink
finishes. A perfectly healthy 2-drink order was flagged **five seconds** in.

ADR-0031's whole argument was that the flat threshold made the marker "close to the default
outcome" rather than a signal. A threshold of zero is that failure with the sign flipped.

The bug was not an oversight — it was an explicit decision, written down and asserted. The
recorder carried a comment saying *"Zero is a legitimate observation — a single-drink order
reaches first_ready_at and ready_at in the same RollUpOrderStatus call, a real zero-spread
sample"*, and a spec pinned it. Both were wrong in the same way, which is why nothing caught
it: the reasoning stopped at *is this observation true?* and never asked *is it true of the
thing being predicted?*

Found by `/code-review high app/services`.

## Decision

`RecordQualitySpread` ignores orders with fewer than two countable drinks.

The principle, stated so the next reader does not re-add them: **learn from the same
population you judge.** `SweepQualityBreaches` only ever flags a drink whose order is still
`partially_ready` — waiting on a sibling — which ADR-0024 chose deliberately and which a
single-drink order is never in. Sampling a population the sweep structurally cannot judge
put the learner and the judge on different distributions.

A solo order's zero is a true fact about that order. It says nothing about how long a *pair's*
first drink sits while the second is made, which is the only quantity this stat predicts.

`countable_items` rather than `order_items`, following the rule established in #58: a failed
drink already has a replacement row, so counting both makes a 2-drink order look like 3.

## Consequences

Only the `"1-2"` class was affected — `"3-6"` and `"7+"` require 3+ drinks, so no solo order
could reach them. Any `QualitySpreadStat` row for `"1-2"` created before this fix is poisoned
and should be deleted so the class re-learns; there is no migration because the feature
shipped hours ago and no store has meaningful history.

A shop whose orders are overwhelmingly single-drink will now take longer to reach
`MINIMUM_SAMPLES` for `"1-2"`, and will sit on the seeded `0.5 × quality_limit_seconds`
multiplier until it does. That is the correct behaviour — better a calibrated seed than a
confident wrong number — and it is what ADR-0031's seeded multipliers exist for.

A regression spec drives the real recorder through ten solo orders and then asserts a healthy
pair is not flagged. It was checked to fail, with that exact message, when the guard is
removed. Pinning it at the *sweep* level rather than the recorder's is deliberate: the defect
was that the learner fed the judge a bad number, and no assertion about either one alone
would have caught it.

## Alternatives considered

| Option | Why not |
|---|---|
| Give single-drink orders their own size class | Fixes the poisoning but invents a bucket for a population the sweep never judges — a threshold nothing can ever consult. The classes exist to mirror §10.4's reporting, not to absorb an implementation problem. |
| Floor `threshold_seconds` at some minimum | Treats the symptom. The EWMA would still be wrong, the floor would be another arbitrary constant of the kind ADR-0031 set out to remove, and the "1-2" threshold would be governed by the floor rather than by anything learned. |
| Weight samples by drink count | More machinery than the problem needs, and still mixes a distribution that is identically zero with one that is not. |
| Require `first_ready_at != ready_at` instead of a drink count | Rejects the *symptom* — and would also drop the genuine case of a multi-drink order whose drinks finish in the same instant, which is real data. |

## Revisit when

The size classes change shape, or a pickup signal makes ADR-0024's `partially_ready` scoping
unnecessary — at which point the population the sweep judges widens, and what the learner
should sample widens with it. The two must move together.

# ADR-0021: The breaking point reads overall p90, not the small-order headline, and caps the swept range at 3x

- **Status:** Accepted
- **Date:** 2026-08-12
- **Design reference:** DESIGN.md §10.4, §10.5 #4

## Context

§10.5 #4 asks for: "Breaking point: raise the demand multiplier until p90 exceeds 15 min.
That number is the store's real capacity." Two things it does not say: *which* p90, and how
far to raise demand looking for it.

**Which p90.** §10.4 names one number "the headline" — small-order p90, because the whole
design claim is about whether a small order's wait stays flat as large orders arrive
(fairness). Capacity is a different question: can the shop serve this demand at all, for a
typical customer, regardless of what they ordered. Reading "p90" in §10.5 #4 as the headline
would make the breaking point a second fairness chart wearing a different name; reading it as
the overall figure across every size class makes it a capacity chart, which is what "the
store's real capacity" is asking for.

**How far to sweep.** Benchmarked at seed 7, 3 stations, DRR with the store's defaults: one
simulated day costs 0.03s at 0.5x demand and 83s at 5x — worse than linear, because a deeper
queue means more dispatch cycles and a larger priority ring to scan each time (§6.2's aging).
Every point past 3x roughly doubled the point before it. Reneging (§10.3) keeps the queue
bounded, but a bounded queue at extreme demand is still a very large one, and dispatch cost
tracks its size.

## Decision

**`Simulator::BreakingPoint` sweeps `POINTS` (0.5x–3x, ten values) and reports the first
point whose *overall* `wait_seconds` p90 — not `by_size_class["1-2"]` — crosses
`target_seconds` (900s / 15 minutes by default) as `capacity`. `capacity` is `nil` when
nothing in range crosses, the same "ceiling, not an answer" convention `StaffingCurve#achieved`
uses.**

At the benchmarked config this is not a close call: overall p90 runs 342s at 1.5x and 1004s
at 1.75x, comfortably either side of the 900s target, so one pooled day settles it without
needing several to separate a real crossing from noise.

3x matches the ceiling already documented on the dashboard's demand slider (§10.6,
`StaffingCurve`'s own comment). A config that still holds at 3x reports `capacity: nil` rather
than the dashboard silently waiting tens of seconds for a point past it — the honest answer to
"we tried up to 3x and it still holds" is to say so, not to keep paying for points nobody is
watching a button for.

## Consequences

- A store that wants a number for a config whose true capacity sits above 3x has to lower
  demand or stations elsewhere on the dashboard and re-read the curve, rather than getting an
  exact figure from one run. This trades precision at the high end for a response the "Find
  breaking point" button returns in single-digit seconds rather than tens of them.
- The small-order-vs-overall distinction means this chart and the quantum sweep's headline can
  legitimately disagree about which policy "wins" — they are answering different questions
  (capacity vs. fairness) and should not be read as the same claim measured twice.

## Alternatives considered

| Option | Why not |
|---|---|
| **Read `by_size_class["1-2"]` p90** (the §10.4 headline) | Answers "is fair queuing still working at this demand", which the quantum sweep and ablation already cover. Capacity is about whether the shop can serve the demand at all, not about one size class relative to another. |
| **True binary search for the exact crossing** | Would return a tighter number than a ten-point grid, at the cost of an unpredictable number of simulated days per click — the grid's cost is known up front and the dashboard can show "Finding…" against it. Given the config-dependent crossing is usually not close (see above), the extra precision is not worth the unpredictability. |
| **Sweep past 3x whenever needed, unbounded** | The literal reading of "raise until it breaks" — but the cost curve makes an unbounded sweep an unbounded wait on a button click. Every other §10.5 experiment (`Ablation::MAX_SEEDS`, `QuantumSweep::POINTS`, `StaffingCurve::STATIONS_TRIED`) already trades exhaustiveness for a bounded, known cost; this is the same trade applied to demand. |

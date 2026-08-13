# ADR-0023: `:slow`-tagged simulator specs run off the default tier

- **Status:** Accepted
- **Date:** 2026-08-13
- **Design reference:** `docs/testing.md` ("What a simulation spec is allowed to cost"), issue #75

## Context

By the time four §10.5 experiments (`Ablation`, `QuantumSweep`, `StaffingCurve`,
`BreakingPoint`) each had a spec file, `bin/rspec` had grown from seconds to 5m33s locally
and 17+ minutes in CI (issue #75), tracked back to the four PRs that landed each experiment
in turn. `docs/testing.md`'s existing rules — stub the ceiling, buy saturation with demand
rather than hours, keep exactly one real end-to-end example per file — were already being
followed, and were not enough. Profiling (`bin/rspec --profile 20`) found why: two problems
neither rule addresses.

**A "narrowed" context was narrow in range, not in cost.**
`spec/simulator/staffing_curve_spec.rb`'s mechanism examples already stubbed
`STATIONS_TRIED` down to `1..3`, but still ran at the file's realistic 1.6x demand — and one
station at 1.6x demand costs 3.16s against 0.14s at three (benchmarked), because a thin
queue means more dispatch cycles and more of the priority ring to scan each one (§6.2's
aging). Narrowing *which* values were tried did nothing when the cheapest of them was still
expensive. That one file's mechanism context cost 58s despite every individual test being a
"just check the mechanism" case.

**The request specs never stubbed anything.** `spec/requests/api/v1/staffing_curves_spec.rb`,
`quantum_sweeps_spec.rb`, and `ablations_spec.rb` each ran the real, unstubbed experiment for
*every* example — including ones testing only routing, auth, and response shape, which have
no dependency on the swept constant's real content. `staffing_curves_spec.rb` alone cost
58.94s this way, the single largest line item in the whole suite.

Fixing both closed most of the gap. What was left — one real, unstubbed, full-range example
per experiment file, kept per the existing "exactly one" rule — was still, correctly, not
free: `Ablation`'s saturation checks (2.2x–2.5x demand, needed for what they prove),
`QuantumSweep`'s ten-point pooled trade-off, `StaffingCurve`'s real 1–8 range, and
`Simulator`'s six-seed Little's Law check together cost about a minute even after everything
above was fixed. That residual is not a bug to trim away — it is the cost of the coverage
those specific examples earn, the same "real, unstubbed" examples `docs/testing.md` already
says to keep exactly one of per file.

## Decision

**Tag that residual `:slow`, and exclude it from the default `bin/rspec` run.**

```ruby
# spec/spec_helper.rb
config.filter_run_excluding :slow unless ENV["SLOW"]
```

```bash
bin/rspec              # fast tier — every push, CI
SLOW=1 bin/rspec       # both tiers — deliberately, before a release or touching app/simulator/**
```

This is the general mechanism `docs/testing.md` already named as the intended shape for
§11's not-yet-built acceptance suite ("the intended shape is a slow-tagged suite ... kept
off every push") — applied here to the §10.5 experiments that needed it first, and reused
rather than duplicated when §11 lands.

## Consequences

- CI does not exercise the real-parameter path on every push. A regression only visible at
  the real range, real demand, or a real pooled-day count (as opposed to the mechanism —
  clamping, reproducing, falling back) will not be caught until someone runs `SLOW=1`
  deliberately. This is the trade being made, not a side effect of it.
- Coverage gates are unaffected: default-tier coverage measured identically before and after
  (99.36% line / 94.23% branch overall, `app/scheduler/**` 100%/100%) — the code paths the
  `:slow` examples exercise were already reached by other, cheaper examples; only the
  *correctness proofs specific to the real parameters* moved tiers, not code coverage.
- `SLOW=1 bin/rspec` — both tiers together — is the number to trust before merging a change
  to `app/simulator/**`, not the default `bin/rspec`. Worth stating explicitly since the
  default tier passing is necessary but no longer sufficient for that class of change.
- Net: 628 examples → 619 default-tier (76.68s from 333s locally), 626 across both tiers
  (163.1s). CI's `Rails — rubocop + rspec` job, uninvestigated when issue #75 was filed at
  17m12s–17m46s, is expected to land near the target it set (under 10 minutes) once this
  merges — not yet confirmed against a real CI run at time of writing.

## Alternatives considered

| Option | Why not |
|---|---|
| **Parallelize the CI job (`parallel_tests` or a matrix split)** | Issue #75's first listed starting point, and still worth doing for whatever cost remains — but it multiplies infrastructure cost to run the same expensive examples faster, rather than asking whether they need to run on every push at all. Narrowing first is cheaper and was enough on its own. |
| **Delete or weaken the expensive assertions** | The residual cost is coverage, not waste — `Ablation`'s saturation behavior and `StaffingCurve`'s real 1–8 range are properties nothing else in the suite checks. Deleting them trades a slow suite for an untested one. |
| **A separate `spec/slow/` directory instead of a tag** | Tags compose with everything RSpec already has (`--profile`, `--only-failures`, running one file's slow examples via `SLOW=1 bin/rspec path/to/file_spec.rb`); a directory split would need its own runner wiring and loses "one file, two tiers" for specs like `staffing_curve_spec.rb` where the fast and slow examples share setup and are easiest to read side by side. |

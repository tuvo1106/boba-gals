# ADR-0019: Prep time is learned after the undo window, not at the finish

- **Status:** Accepted
- **Date:** 2026-08-09
- **Design reference:** DESIGN.md §5.2 (undo discards the sample), §7.3 (learned prep times), §9.4 (KDS)

## Context

§5.2 requires the KDS undo to "discard the prep-time sample so the EWMA (§7.3) doesn't
learn from phantom durations". It did not. `FinishDrink` recorded the sample inline and
`UndoLastAction` reverted the status and left the sample behind (issue #69).

The damage is not one bad number. A mistap skews **early** — the wrong card, or a tap
before the drink is actually done — so phantom durations are short and the bias is
systematic and downward. A low EWMA feeds §7.1's projection, the board quotes short, and
§7.3 calls that the difference between a board customers trust and one they learn to
ignore. `RecordPrepTime`'s `[0.25x, 4x]` outlier guard does not catch it: a mistap
produces a *plausible* duration, not an absurd one. Measured, one undone 20-second mistap
moved a 60-second learned value to 52.

The obvious repair — subtract the sample back out — is not available. An EWMA is not
cleanly invertible. `new = ALPHA * observed + (1 - ALPHA) * old` solves for `old` but
drifts in floating point, and it is simply wrong once a second sample for the same menu
item has landed in between. Nothing serialises a finish on one drink against an undo on
another drink of the same menu item, and two `web` pods (§14.2) make that ordinary rather
than exotic.

So the fix has to be about *when* learning happens, which is a design decision rather than
a patch.

## Decision

**Nothing is learned until there is nothing left to undo.** `FinishDrink` enqueues
`RecordPrepTimeJob` with a `UndoLastAction::WINDOW` delay instead of calling
`RecordPrepTime` inline. A mistap that gets undone never reaches a recorder, so §5.2's
"discard the sample" is satisfied by never taking it.

The undo window stays a single constant. `UndoLastAction::WINDOW` is the canonical one and
the job reads it; the frontend's `UNDO_WINDOW_SECONDS` is a documented mirror for the
countdown affordance. The delay is not a third copy of `60`, deliberately — shortening the
window in one place and not the other is precisely how this bug comes back.

The job carries the `finished_at` it was enqueued for and records only if the item is
still `finished` **and** still carries that exact stamp. An undo followed by a re-finish
enqueues two jobs and both find a `finished` item, so a status check alone would teach the
board one drink twice — the same corruption in the other direction. Matching the stamp
means each job only records the finish it was scheduled for.

Comparing the stamp rather than elapsed time is the part worth noting: an "is the window
closed yet?" check would double-count as soon as a backlogged queue ran both jobs late,
and would silently *lose* a sample if a job ever fired a millisecond early. The stamp is
correct regardless of when the job actually runs.

## Alternatives considered

| Option | Why not |
|---|---|
| **Snapshot `previous_ewma` / `previous_sample_count` on `PrepTimeStat` and restore on undo** | Correct exactly one level deep, and wrong under interleaving — two drinks of the same menu item finishing between a finish and its undo restores a value that was never current. It also adds two columns whose only purpose is to describe a 60-second window, and puts write contention on a row every finish already touches. |
| **Store raw samples and recompute the EWMA** | Correct, and far heavier than the problem: an unbounded per-drink table, a recompute on every undo, and a second source of truth for a number §7.3 defines as a running average. Reach for it only if prep times ever need to be re-derived for another reason. |
| **Invert the EWMA arithmetically** | Not available. Floating-point drift accumulates, and it breaks outright once another sample lands in between — which nothing prevents. |
| **Keep recording inline and accept the bias** | The bias is signed, not random, so it does not average out over a shift. §5.2 is explicit, and it is on CLAUDE.md's non-negotiables list. |
| **Record inline but delete the sample on undo via a `prep_time_recorded_at` claim column** | Solves double-counting but not inversion — the sample is already blended by the time undo runs. Adds a column that the deferral gets for free. |

## Consequences

Learning lags a finish by 60 seconds. This is irrelevant to an EWMA over a shift: `ALPHA`
is 0.2, `MINIMUM_SAMPLES` is 10, and §7.3's purpose is to track the shop over hours, not
to react to the last drink. The first drink of the day now teaches the board a minute
after it is made rather than instantly.

A sample can now be lost where it previously could not — a scheduled job sits in Redis,
and a Redis loss drops it. That asymmetry is the right way round: losing an occasional
observation slows convergence, while learning a phantom one biases the board. Every guard
in the job fails closed for the same reason.

`FinishDrink` is no longer the whole story of §7.3. Anything asserting on prep-time
learning through a finish has to run the enqueued job, and `spec/services/finish_and_undo_spec.rb`
does exactly that — the regression examples assert on `PrepTimeStat` rather than on the
job, so they stay true if this mechanism is ever replaced.

The undo window is now load-bearing in a third place. It was already the API contract
(§9.1) and the KDS countdown; it now also decides when the shop learns. That is the
argument *for* this shape — the concept lives in one constant — but it means changing 60
seconds is a bigger act than it looks.

## Revisit when

- Prep times need to be re-derived from history for any other reason. Storing raw samples
  would then be paid for already, and this deferral could collapse into it.
- The undo window becomes per-store configurable. The delay must follow the same value the
  KDS is counting down, not a default.

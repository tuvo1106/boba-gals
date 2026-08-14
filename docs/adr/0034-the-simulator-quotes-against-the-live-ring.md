# ADR-0034: The simulator quotes against the live ring

- **Status:** Accepted
- **Date:** 2026-08-14
- **Design reference:** DESIGN.md §7.1, §10.1, §10.3, §10.4
- **Relates to:** ADR-0004, ADR-0011, ADR-0013, ADR-0014

## Context

`Simulator::Projection` is the simulator's copy of `ProjectEta` — §7.1's forward projection,
run through the real `Scheduler.pick_next`. Both files state they are mirrors and must not
drift. They had drifted, and its own comment said so without meaning to:

```ruby
# Deficits are copied by value and the ring starts where it stands.
def fresh_state
  ...
  DeficitScheduler::State.new(flows: flows, config: @config)   # no deficits, no pointer
end
```

Every flow was built at `deficit: 0` and the ring started at `pointer: 0`, while `ProjectEta`
loads both from Redis via `SchedulerStateStore#load`. So the simulator quoted customers
against a scheduler state the shop was never in.

This matters more than a stale estimate. §10.3 has customers **renege against the quote** —
the number they are told is what they decide on — so an inaccurate quote does not just
mis-report §10.4's ETA error, it changes who walks out, which changes the queue, which
changes every downstream figure. And it was invisible: the whole suite passed, because
nothing asserted the projection carried anything.

Found by `/code-review high app/simulator`, which flagged the comment contradicting the code
three lines below it.

## Decision

`Simulator::Projection` takes `deficits:`, `pointer:` and `granted_to:`, and `World#quote_for`
passes them from the live `@state`. Deficits travel as a plain `{id => number}` hash and every
`Flow` and the `State` are still constructed fresh, so `pick_next` draws down the projection's
own objects and the running shop is untouched — the property the isolation specs pin, and the
reason the original comment was written.

The pointer is copied as an **index** rather than mapped through a flow id the way
`SchedulerStateStore` does. That is safe here specifically: the projection's flow set is the
live set with the arriving order appended, so every existing flow keeps its position. It would
not be safe if the projection ever reordered or filtered the live set differently.

## What it changed

12 pooled seeds, 3 stations, per demand level. `eta_*` are seconds.

| demand | metric | before | after |
|---|---|---|---|
| ×1.0 | p50 abs error | 16.8 | **15.4** |
| ×1.0 | p90 abs error | 58.3 | **49.0** |
| ×2.0 | p50 abs error | 45.9 | **25.9** (−44%) |
| ×2.0 | p90 abs error | 373.9 | **207.7** (−44%) |
| ×2.0 | reneged | 270 | **195** (−28%) |
| ×2.6 | p50 abs error | 199.2 | **55.7** (−72%) |
| ×2.6 | p90 abs error | 1240.6 | **513.3** (−59%) |
| ×2.6 | reneged | 1513 | **1211** (−20%) |

The estimator is dramatically more accurate once it estimates the shop it is actually in, and
the effect grows with load — which is what you would expect, since deficits and ring position
only matter once there is a queue to carry them.

**But the bias moved the other way, and that is the more interesting result.** Signed bias
(positive = the customer waited longer than quoted) went from −7.0 to **+293.0** at ×2.6, and
from +14.2 to **+79.6** at ×2.0.

Before, the errors were enormous but roughly symmetric, so they cancelled and the bias read
near zero — a shop that is wildly wrong in both directions looks unbiased. Carrying the
deficits makes the projection see work dispatch sooner, so quotes shorten, and what surfaces
is a **systematic optimism that production has and the simulator was masking**. §7.3 is blunt
that bias, not absolute error, is what destroys trust in the board. That property was always
there in `ProjectEta`; the simulator simply could not see it.

Reneging falling 20–28% follows from the same thing: shorter quotes mean fewer people walk
out, so the simulator had been over-reporting lost customers.

## Consequences

**Figures recorded before this are not comparable to figures after it.** ADR-0013's and
ADR-0014's tables, and anything quoting a renege count or an ETA-accuracy number, predate this
and should be read as historical — the same caveat ADR-0014 already carries for figures taken
before reneging switched to the §7.1 projection. Nothing recorded is *wrong*; it measured a
simulator that quoted differently.

The revealed positive bias is now a real open question about production, not an artefact:
the shop's ETA is systematically optimistic at load, by roughly 10% of the wait at ×2.6.
Whether to correct that — `eta_safety_factor` is the obvious lever, and §7.1 already
multiplies by it — is a separate decision that wants its own measurement.

Three specs now pin this (`spec/simulator/projection_spec.rb`), and each was checked to fail
with its half of the change reverted. One of them was wrong on the first attempt in a way
worth recording: it used a 60s drink against a 60s quantum, where one grant always suffices,
so the carried deficit never decided anything and the example passed identically against the
unfixed code. A deficit is only observable when an item costs **more** than the quantum.

## Alternatives considered

| Option | Why not |
|---|---|
| Correct the comment, accept the divergence | The comment was right about what *should* happen; the code was wrong. And §10.1's whole premise is that the simulator runs the production path — a quote computed from a different scheduler state is exactly the "tuning a model of your system rather than your system" failure it exists to prevent. |
| Carry deficits but not the pointer | Half a fix. The pointer decides which flow is asked first among equals, so starting every quote at 0 quietly re-privileges whichever flow sits at index 0. |
| Have the projection share the live `State` | What the original comment was written to forbid, and correctly: `pick_next` mutates what it is given, so a quote would consume the real queue's deficits and reorder what the kitchen makes next. |
| Map the pointer by flow id, as `SchedulerStateStore` does | Unnecessary here — the projection's flow set preserves live indices. Worth revisiting if that ever stops being true. |

## Revisit when

Anything changes the projection's flow set so it no longer mirrors the live one positionally
— then the pointer needs mapping by id. Or when someone decides what to do about the
now-visible ETA optimism at load.

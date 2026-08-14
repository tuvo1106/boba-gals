# deficit_scheduler

Deficit round robin work scheduling as a pure function.

```ruby
state = DeficitScheduler::State.new(
  flows: [
    DeficitScheduler::Flow.new(
      id: 42, arrived_at: Time.now,
      queue: [ DeficitScheduler::Item.new(id: 1, cost: 60, enqueued_at: Time.now) ]
    )
  ],
  config: DeficitScheduler::Config.new(quantum: 60)
)

DeficitScheduler.pick_next(state, Time.now)
# => { flow: #<Flow id=42>, item: #<Item id=1> }
```

`pick_next` reads no clock, touches no database, and performs no I/O. `now` is injected. That
is what lets a simulator run the *production* scheduler unmodified against a simulated clock —
if the scheduler could read the wall clock, simulated results would stop describing production.

The gemspec declares **zero runtime dependencies**, on purpose. That is the boundary: this
scheduler cannot quietly grow a Rails call, because adding one means adding a dependency on
purpose.

## The model

A **flow** is a set of related items that compete as one unit. An **item** is one piece of
work with a `cost`. Scheduling happens *between flows*, not between items — so a flow holding
fifteen items competes for one turn of the ring rather than fifteen.

That is the whole idea, and it is what stops a large batch from blocking every small one
behind it. Under plain FIFO, an item arriving behind a fifteen-item batch waits for all
fifteen. Here it waits roughly one item's time.

## Why a deficit

Equal *turns* are not equal *service*. If one flow's items cost 135 and another's cost 40,
plain round robin hands the first flow 3.4× the capacity per round while looking fair.

Each flow accrues a `quantum` per visit and spends it on items it can afford. What it cannot
spend **carries over** — that carried remainder is the deficit the algorithm is named for, and
it is what stops a flow with expensive items being starved by the rounding. Over time every
flow receives service in proportion to its quantum rather than to its turn count.

(Shreedhar & Varghese, *Efficient Fair Queueing using Deficit Round Robin*, 1995.)

## The four boosts

Each is additive on the quantum multiplier, never multiplicative — stacking them
multiplicatively would let one flow dwarf the rest by an order of magnitude.

**Aging** (`aging_rate`) grows a flow's quantum with how long it has waited, so nothing
starves even under a continuous stream of newer, smaller flows. Clamped at zero so clock skew
between two processes cannot produce a negative multiplier, which would shrink the deficit on
every visit instead of growing it and eventually trip the livelock guard.

**Staleness** (`staleness_boost`, off by default) grows a flow's quantum with how long its
*earliest completed item* has been sitting undelivered — for work that is delivered as a
batch, where partial output degrades while the rest is produced.

Keyed on elapsed sitting time rather than on fraction-complete, deliberately. Those are
different quantities: a flow can be 90% done with nothing sitting, or 30% done with its first
output going off. The fraction-complete version was measured and made the thing it was meant
to fix monotonically *worse*, because it accelerated flows past halfway using capacity taken
from flows approaching halfway — precisely the ones whose first output was already waiting.
Re-keyed on sitting time it no longer backfires, but it does trade median wait for it, which
is why it ships off. See ADR-0014 and ADR-0032 in the parent repo.

**Expedited** is a priority *tier*, not a bigger number. `expedited_multiplier` gives such a
flow more throughput once its turn comes, but the ordering guarantee lives in the ring order:
a flow holding expedited work is asked first regardless of age. A fixed bump could not deliver
that — with the default aging rate an ordinary flow overtakes a `+4.0` bump after about 27
minutes of waiting. A floor has to be a tier or it is not a floor.

**Deadlines** (`deadline`, `deadline_buffer`) schedule *backward*: a flow due at 11am with 20
minutes of work is not started at 9am. It becomes eligible at `deadline - remaining_work -
deadline_buffer`.

## Comparison arms

`policy` also accepts `fifo`, `rr` and `sjf`. These exist to measure what the deficit actually
buys — each removes one thing DRR does, so a benchmark can attribute the difference to it.
`sjf` in particular minimises mean wait (provably, on a single server) *by starving large
flows*, which is the failure this scheduler exists to prevent. It is a bound to measure
against, never a setting to ship.

## Config

| Key | Default | Meaning |
|---|---|---|
| `policy` | `:drr` | `:drr`, or a comparison arm |
| `quantum` | `60` | service granted per visit, in `cost` units |
| `aging_enabled` / `aging_rate` | `true` / `0.15` | multiplier added per minute waited |
| `staleness_enabled` / `staleness_boost` | `false` / `1.0` | multiplier added per minute the first output has sat |
| `expedited_multiplier` | `4.0` | multiplier added while expedited work is queued |
| `deadline_buffer` | `120` | slack subtracted when backward-scheduling |

`Config.from_h` accepts string or symbol keys and drops unknown ones, so a caller can hand it
a deserialized config carrying keys this library has no business reading.

## A note on vocabulary

This library speaks `cost`, `expedited` and `deadline`. Its origin — and only current
consumer — is a boba shop, where those are `prep_seconds`, `remake` and `promised_at`. The
translation lives in that application (`BuildSchedulerConfig`), not here: a scheduler that
knew what a drink was could not be used for anything else, and a consumer's persisted key
names are its own business.

## Status

Not published. It is consumed as a path gem by the application it was extracted from, where
the payoff is the enforced boundary rather than reuse. If it is ever published, the namespace
should be reconsidered first — see ADR-0033 in the parent repo.

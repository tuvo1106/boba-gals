# ADR-0011: The simulator draws from per-entity substreams

- **Status:** Accepted
- **Date:** 2026-08-08
- **Design reference:** DESIGN.md §10.1, §10.2, §10.3, §10.5, §17

## Context

§10.2 promises that "a run is a pure function of its seed", and §10.5's sweeps and ablations
all rest on comparing two runs that differ in exactly one setting. Until now the simulator
drew every random value from a single `Rng`, seeded once.

That is enough for reproducibility — the same seed does give the same run — but it is not
enough for comparison, and comparison is what the dashboard is for.

Arrivals are scheduled up front, so the arrival stream is stable. But two draws happen
*during* the run, at times the scheduler controls:

- `on_finished` draws `chance(remake_rate)` to decide whether a drink went wrong
- `on_finished` draws `exponential(mean)` for the pickup delay

Both fire in **drink-completion order**, which is precisely what changing the policy changes.
The first reordered completion shifts every subsequent draw by one, and the two runs never
resynchronise.

Measured at seed 7, three stations, DRR against FIFO:

| | DRR | FIFO |
|---|---|---|
| drinks made | 757 | 755 |
| remakes | 19 | 15 |
| shared drinks with identical intrinsic prep time | **105 of 740** | |

Drink `32-0` — the same drink, of the same order, at the same seed — took 129.7s under DRR
and 27.2s under FIFO. That is not a scheduling effect; that drink was drawn from a different
part of the stream.

So every A/B the dashboard offered measured *policy plus a different random day*, with no way
to separate the two. The direction of the DRR/FIFO result was almost certainly right, being
large and consistent, but the magnitude was not a number anyone should quote — and the
ablations in §10.5 (aging on/off, cohesion on/off) have smaller effects that this noise could
plausibly swamp entirely.

## Decision

`Rng#stream(purpose, key)` returns an independent substream seeded from
`SHA256("#{master_seed}:#{purpose}:#{key}")`, memoised per key. Every draw in the simulator
moves onto a substream keyed by the entity it is about:

| Stream | Key | Draws |
|---|---|---|
| `:arrivals` | — | inter-arrival times, thinning, order size |
| `:stations` | — | per-barista skill |
| `:order` | order id | kiosk vs web, order-ahead, promise offset |
| `:drink` | drink id | menu item, lognormal prep time |
| `:quality` | drink id | whether the drink goes wrong |
| `:pickup` | order id | collection delay |
| `:renege` | order id | the customer's patience |

What a drink *is* now depends only on which drink it is. The scheduler can dispatch it first
or last, or not at all, without changing it.

Two consequences worth naming:

**Remake ids became per-lineage.** A remake was `"#{drink.id}r#{@remakes}"`, using a global
counter — which is itself policy-dependent, so the same failure produced a different id under
a different policy, and the id is the substream key. Remakes are now `"#{drink.id}r"`,
chaining for a remade remake.

**SHA-256, not `String#hash`.** Ruby randomises `String#hash` per process. Deriving substreams
from it would make a seed replayable only within a single boot, which is worse than the
problem being fixed and would have failed silently and intermittently.

## Consequences

At seed 7, DRR and FIFO now make **the same 639 drinks with identical intrinsic prep times**,
and 125 of them land on a different station — which is the scheduling effect, correctly
isolated.

Absolute figures moved, because reneging now draws from a different stream and so a different
set of customers walks away. Any number recorded from a run before this change should be
re-measured rather than compared against.

Two latent bugs surfaced once the streams shifted, both pre-existing and both now fixed:

- An order-ahead order could be promised a pickup time after closing. §6.2's backward
  scheduling then correctly refused to dispatch it, and it sat in `@pending` forever — counted
  as neither served nor lost, absent from every metric. Promises are now bounded by opening
  hours. The conservation spec had been passing on luck.
- `"does not renege in a shop that is keeping up"` asserted exactly zero reneges. At seed 7,
  nine of 142 web arrivals are quoted over the 480s threshold and one leaves — legitimate
  under §10.3's soft ramp. The assertion was pinned to one alignment of the streams rather
  than to anything the model claims, and is now a rate bound.

Cost is one SHA-256 and one `Random` allocation per distinct key, memoised. A day runs in
single-digit milliseconds still, so §10.5's sweeps are unaffected.

## Alternatives considered

**Separate `Rng` per concern, not per entity.** Cheaper, and it fixes the arrival stream. But
`:quality` draws would still be consumed in completion order, so drink X would still get a
different draw depending on when X was made. It fixes the symptom between streams and leaves
it within them.

**Pre-draw everything at construction.** Decide each drink's prep time and remake outcome when
the order is built. Equivalent in effect and slightly faster, but it pushes knowledge of every
random decision into `build_order`, and adding a new stochastic process later means threading
another field through the struct rather than calling `stream`.

**Accept the noise and average over many seeds.** Legitimate — it is what §10.5's sweeps
already do for the headline chart. But it does not help the dashboard, which shows one day at
a time and invites exactly the two-run comparison this makes honest, and it needs far more
runs to resolve the smaller ablation effects.

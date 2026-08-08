# ADR-0009: The ring is walked in priority order, and the remake floor is a tier

- **Status:** Accepted
- **Date:** 2026-08-08
- **Design reference:** DESIGN.md §6.1, §6.2, §6.4, §11, §12 step 5

## Context

Implementing §6.2's pseudocode against §11's required test list surfaced two places where
the design contradicts itself. Both were found by writing the checklist as real examples,
which is exactly why §11 says not to merge the scheduler without them.

### The quantum grant lets one order monopolise the ring

§6.2 grants a quantum *inside* the dispatch loop with nothing recording that a flow has
already been granted this round:

```ruby
flow.deficit += quantum_for(flow, now, state.config)
state.pointer += 1 if flow.deficit < head.prep_seconds
```

The pointer only advances when the freshly granted quantum still isn't enough. So a flow
whose quantum covers its next drink dispatches, keeps the pointer, and on the next call
tops itself up again — indefinitely. With the default 120s quantum against 60s drinks, the
first order in the ring drains completely before any other order is touched.

That is FIFO with extra steps, and it is precisely the behaviour §2 exists to prevent. This
is a bug in the pseudocode, not a design decision: deficit round robin is defined as **one
quantum per flow per round**, and §6.1 names the algorithm.

### The quantum multiplier is a rate, not a rank

§6.4 says remakes "always outrank same-age normal work". §11 requires an example asserting
it, and another for cohesion: "an order past 50% completion outranks an equal-age order at
0%".

Neither is achievable with §6.2's ring. Measured, before any change — two same-age orders,
20 drinks each, one carrying a remake:

```
first 10 dispatched: normal, normal, remade, remade, remade, remade, remade, remade, remade, remade
share over 40:       remade=20  normal=20
```

The multiplier works: 5× quantum buys ten drinks per round against two. But `normal` still
goes first, because the ring is walked in arrival order and index 0 is asked first. A
quantum multiplier decides *how much service per round*, never *who is asked first*.

### And the floor is a bump

§6.4 is explicit: "A fixed additive bump gets swamped: after 20 minutes of aging, a normal
order's multiplier exceeds a fresh remake's." It then prescribes a floor — and §6.2
implements `multiplier += config.remake_multiplier`, which is a fixed additive bump. With
the default rates a normal order overtakes a fresh remake at about 27 minutes
(`1 + 0.15 × 27 ≈ 5.0`). The design diagnoses the failure and then ships it.

## Decision

**Walk the ring in priority order rather than arrival order**, and make the remake floor a
tier:

```ruby
state.flows.each_with_index.sort_by do |flow, index|
  [ flow.pending_remake? ? 0 : 1,           # the floor (§6.4)
    -quantum_for(flow, now, state.config),  # aging and cohesion
    index ]                                 # stable, so ties are deterministic
end
```

**This costs nothing in fairness.** DRR's fairness lives in the deficit accounting, not in
the visit order — every flow still draws exactly one quantum per round and still carries its
unspent remainder, so nothing starves. Reordering visits changes only who is asked first
within a round, which is the property §6.4 and §11 were asking for and not getting.

**A floor has to be a tier.** Any number added to a multiplier can be exceeded by a
sufficiently aged competitor; that is what "swamped" means, and it is true of `+= 4.0` just
as it was of whatever bump §6.4 was arguing against. Sorting remakes into their own tier
makes "always outrank" literally true, while `-quantum_for` inside the tier keeps §6.4's
other requirement: two remakes still compete with each other by age.

`remake_multiplier` stays in `quantum_for`. It is no longer carrying the ordering guarantee,
but it still earns its place — it is what lets a remade order *clear* faster once its turn
comes, rather than merely starting sooner.

**One quantum per flow per visit**, tracked by `Scheduler::State#granted?`, keyed on flow id
rather than pointer index so it survives the ring being re-sorted between calls.

Rejected alternatives:

- **Reinterpret §11 as throughput share.** Zero code change; the tests would assert that a
  remake gets more service per round, which it already did. Rejected because §6.4's wording
  is "always outrank", and a customer whose drink was dropped does not care that their
  replacement has a higher long-run service rate.
- **Full priority scheduling** — highest multiplier always wins, no ring. Delivers the
  ordering and abandons DRR, reintroducing exactly the starvation the deficit exists to
  prevent.
- **Seed each round's deficit from the multiplier.** Does not address ordering at all; the
  ring still decides who is asked first.

## Consequences

**This contradicts §6.2, and DESIGN.md needs three edits** in its own PR: the grant loop
(a bug), the ring's walk order, and §6.4's floor being a tier rather than an additive term.

**The ring is re-sorted on every call.** `priority_ring` is O(n log n) per dispatch against
an in-memory flow set that §6.5 caps at boba-shop volume — hundreds of orders a day, "low
thousands of drinks". Reconsider above ~50 orders/hour sustained, which is the same
threshold §6.5 already sets for materialising a queue table.

**The persisted pointer now indexes a priority-ordered ring.** §6.5 stores it as an order id
rather than an index precisely because indices are meaningless across rebuilds, so this
changes nothing about persistence — but the flow it resumes at is now determined by priority
rather than arrival.

**Mutation testing found what coverage could not.** At 100% line and branch, `mutant` left
70 mutants alive. Five were real gaps, including that no cohesion example covered a
**two-drink order** — §6.4's own motivating case — and that every one sat exactly on the 0.5
threshold, so `>=` could have degraded to `==` unnoticed. Now 93.14%; the remainder are
equivalent mutants (`guard = 0` → `1` against a 10,000 limit, `0` → `-1` in a sort tier) and
default-argument removals that no caller exercises.

# ADR-0012: DRR is kept for operability, not for O(1)

- **Status:** Accepted
- **Date:** 2026-08-08
- **Design reference:** DESIGN.md §6.1, §6.2, §6.5, §14.2
- **Relates to:** ADR-0009

## Context

§6.1 sells deficit round robin on the property it was invented for. Shreedhar and Varghese
proposed DRR in 1995 as an **O(1)** alternative to weighted fair queueing, which needs a
priority queue over virtual finish times and therefore costs O(log n) per packet. DRR's whole
trick is that it replaces "sort by who deserves service most" with "walk a ring and carry the
remainder", buying comparable fairness with no ordered structure at all.

ADR-0009 then spent that property. Giving remakes the §6.4 priority floor required ordering
the ring, and `Scheduler.priority_ring` now sorts every flow on every dispatch:

```ruby
state.flows.each_with_index.sort_by do |flow, index|
  [ flow.pending_remake? ? 0 : 1, -quantum_for(flow, now, state.config), index ]
end.map(&:first)
```

That is O(n log n) per drink. Nothing in the repository records that the headline argument
for choosing DRR no longer applies, which leaves the next reader with a stated rationale that
the code contradicts.

## Decision

Keep DRR, and state the actual reason: **it is the fair-queueing algorithm whose entire state
is one integer per flow.**

That matters here for reasons that have nothing to do with asymptotics:

- **§6.5 persists the scheduler to Redis** and §14.2 runs two `web` pods from the first
  deploy. DRR's per-flow state is a deficit counter — `INCRBY`-able, order-independent, and
  harmless to lose (a dropped deficit costs one flow part of one turn). WFQ's state is a
  virtual-time clock shared across all flows, which two pods must not let drift, and which is
  meaningless if partially restored.
- **§6.2 requires the scheduler to be a pure function** so the simulator runs it unmodified.
  A deficit is trivially serialisable into `Scheduler::State`. A virtual clock would have to
  be reconstructed identically in the simulator or every result would be about a different
  algorithm.
- **Scale makes the complexity argument moot in both directions.** `n` is the number of open
  orders — a few dozen at the §10.3 peak. An O(n log n) sort over 40 flows is not measurable
  next to a 40-second drink.

So the trade ADR-0009 made was sound; only its justification was left unwritten. We did not
give up performance we needed. We gave up an asymptotic property that was never load-bearing
at shop scale, in exchange for a correctness guarantee (§6.4's floor) that was.

## Consequences

§6.1's O(1) claim is now false of this implementation, and should be read as describing
textbook DRR rather than the code. That is worth knowing before anyone "optimises"
`priority_ring` back into a ring walk and silently removes the remake floor.

If `n` ever became large — a franchise-wide scheduler over thousands of concurrent orders —
this decision would need revisiting, and the resolution would not be to drop the floor. A
heap keyed on `[pending_remake, -quantum]` restores O(log n) while preserving ADR-0009's
ordering exactly. That is a mechanical change, and worth doing only when there is a
measurement demanding it.

## Alternatives considered

**Switch to WFQ, since we are paying for ordering anyway.** Coherent — WFQ has tighter delay
bounds than DRR and we have already forfeited the cost advantage. Rejected on the operability
argument above: the virtual-time clock is shared mutable state across two pods, which §14.4
already identifies as the class of bug this design is trying to avoid, and it complicates
§6.5's restore path for a bound nothing has yet asked for.

**Restore O(1) by dropping the remake floor.** Rejected: ADR-0009 exists because the
multiplier alone could not make remakes outrank, measured. The floor is a correctness
property and the sort is what buys it.

**Say nothing, since the code works.** Rejected. §6.1 is the section a reader consults to
learn why this algorithm was chosen, and it currently gives a reason the code does not
support. A rationale that is quietly false is worse than no rationale.

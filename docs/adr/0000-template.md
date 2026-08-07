# ADR-0000: <short title, a noun phrase>

- **Status:** Proposed | Accepted | Superseded by [ADR-XXXX](xxxx-slug.md)
- **Date:** YYYY-MM-DD
- **Design reference:** DESIGN.md § <!-- or "not covered by the design" -->

## Context

What is the situation that forces a decision? Include the constraints that actually
narrow the options — volume, the two-`web`-pod topology, the pure-function scheduler
rule, whatever applies. Someone reading this in a year should understand the pressure
without reading the code.

## Decision

What we're doing. Present tense, active voice: "We store deficits in Redis keyed by
`sched:{store_id}:deficit:{order_id}` with a 6h TTL."

## Alternatives considered

| Option | Why not |
|---|---|
| | |

## Consequences

What becomes easier. What becomes harder. What we've now committed to that would be
expensive to undo. Be honest about the costs — an ADR that lists only benefits is
marketing, not a record.

## Revisit when

The concrete trigger that should make someone reopen this. "Above ~50 orders/hour
sustained" beats "if it becomes a problem."

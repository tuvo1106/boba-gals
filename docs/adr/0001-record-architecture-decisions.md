# ADR-0001: Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-08-06
- **Design reference:** n/a — this is process, not architecture

## Context

`DESIGN.md` is a complete pre-implementation specification. It already settles the large
questions and marks several as **locked** (§3). But implementation always surfaces
decisions the design didn't anticipate: a gem choice, a serialization format, a way to
structure the Redis keyspace, a workaround for something that turned out not to work.

Those decisions currently have nowhere to live. Left in commit messages they are
unfindable; left in PR comments they die with the PR; left in code comments they explain
the *what* but rarely the alternatives.

## Decision

We keep an ADR log in `docs/adr/`, numbered sequentially, using `0000-template.md`.

The division of responsibility:

- **`DESIGN.md`** holds the specification and the decisions made before implementation.
  It is edited only in a dedicated PR, and such a PR changes nothing else.
- **ADRs** hold decisions made *during* implementation that `DESIGN.md` doesn't cover, and
  any decision that **contradicts** the design (which must also update `DESIGN.md` and say
  so in both places).

An ADR is warranted when the decision is hard to reverse, non-obvious to the next reader,
or was arrived at after rejecting a plausible alternative. Routine choices that any Rails
developer would make the same way do not need one.

ADRs are immutable once accepted. To change a decision, write a new ADR and mark the old
one `Superseded by ADR-XXXX`.

## Alternatives considered

| Option | Why not |
|---|---|
| Fold everything into `DESIGN.md` | The design doc is a specification with a coherent argument. Appending a running log of implementation choices would wreck its readability, and it would no longer be reviewable as a single document. |
| Wiki | Drifts from the code, isn't reviewed, isn't versioned with the change that motivated it. |
| Nothing — rely on git history | Answers "what changed," never "what else we tried and why it lost." |

## Consequences

Decisions become reviewable: an ADR arrives in the PR that implements it, so the reasoning
is critiqued while it is still cheap to change. The cost is a small tax on every
non-obvious change, and a judgment call each time about whether a decision clears the bar.
That judgment erring toward "write it" is the cheaper failure.

## Revisit when

The log exceeds roughly 40 entries and finding things becomes the problem — at which point
add an index with tags, not a different system.

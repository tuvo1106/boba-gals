# ADR-0033: The scheduler is a generic path gem

- **Status:** Accepted
- **Date:** 2026-08-14
- **Design reference:** DESIGN.md §6.1, §6.2, §6.6, §10.1
- **Relates to:** ADR-0002, ADR-0009, ADR-0014, ADR-0023, ADR-0032
- **Supersedes:** the `app/scheduler/**` *path* in ADR-0002 and ADR-0023. Both ADRs' policies
  are unchanged and still in force — the 100% line-and-branch gate, mutation testing scoped to
  the scheduler, and the `:slow` tier. Only the location moved. ADRs are immutable, so neither
  file was edited.

## Context

Issue #62 proposed extracting `app/scheduler/` into a gem and was honest about the case
against: "A gem earns its keep when a **second consumer** exists. Ours is the simulator, which
lives in this repo and already imports the scheduler directly."

Re-measuring before acting (the issue's figures predate ADR-0032's changes):

| #62's claim | Measured |
|---|---|
| 717 lines, 5 files | **468 lines**, 5 files |
| 0 Rails references | **Confirmed** — two comments saying "no ActiveRecord" and one `sum`, core Ruby since 2.4 |
| — | **4 of 7** scheduler commits also touched consumers atomically |

So #62's strongest stated trigger — "the no-Rails rule gets broken by accident and the spec
helper does not catch it" — is *measurably false*. The discipline held across every commit.

That left the honest payoff smaller than "we can reuse it", exactly as #62 said. What changed
the calculus was a different question: **make it generic, so it isn't about drinks at all.**
The algorithm is textbook deficit round robin (Shreedhar & Varghese, 1995) plus aging,
priority tiers, deadline scheduling and a staleness boost. The entire interface it needs from
an item is a cost, two tiebreak fields, and an expedite flag. Nothing about drinks ever
reached the algorithm — only the vocabulary. A gem that speaks `cost`/`expedited`/`deadline`
*can* have a second consumer; one that speaks `prep_seconds`/`remake` cannot.

## Decision

**`gems/deficit_scheduler`, consumed via `path:`.** Not a separate repository and not
published. The 4-of-7 cross-boundary figure is why: with a separate repo, most scheduler
changes become two pull requests plus a version bump and a release before the app can use
them. Today's ADR-0032 work would have been exactly that. A path gem gets the boundary at a
fraction of the cost, and publishing later is mostly a `git mv`.

**The boundary is the gemspec, not a convention.** It declares zero runtime dependencies, so
the scheduler cannot grow a Rails call without someone adding a dependency on purpose. That is
strictly stronger than the previous guarantee, which was a spec helper that chose not to
require `rails_helper`. The source-reading purity guard moved with the code and was *widened*
from one file to every file in `lib/`.

**Generic vocabulary in the gem; this shop's vocabulary everywhere else.**

| Gem | Application |
|---|---|
| `Item#cost` | `prep_seconds` |
| `Item#expedited?` | `remake?` |
| `Flow#pending_expedited?` | `pending_remake?` |
| `Flow#deadline` | `promised_at` |
| `Flow#first_output_at` | `first_ready_at` |
| `Config#staleness_enabled/_boost` | `cohesion_enabled/_boost` |
| `Config#expedited_multiplier` | `remake_multiplier` |
| `Config#deadline_buffer` | `promise_buffer` |
| `Config.from_h` | was `from_store` |

**`BuildSchedulerConfig` is the only place the two vocabularies meet.** §6.6's key names are
untouched in `stores.scheduler_config`, in the admin API, in `docs/api/openapi.yaml`, in the
generated frontend types and on the dashboard — so nothing operator- or customer-facing
churned for a refactor, and no data migration was needed. This is correct layering rather than
a compromise: a second consumer would never want to inherit this shop's database key names,
and the gem has no business knowing what our persistence looks like.

The obvious alternative — renaming the persisted and published keys too, for one vocabulary
everywhere — was rejected as disproportionate: it needs a migration over existing
`scheduler_config` rows, a §6.6 rewrite in its own dedicated PR, regenerating the OpenAPI
document and frontend types, and dashboard copy. Three PRs to remove one small mapping.

**`Config.from_store` was already generic and merely misnamed.** #62 expected it to need "a
store-shaped adapter left on the app side," but it only symbolizes keys and drops unknown
ones, and its two callers already passed different shapes. Renamed `from_h`; no adapter
needed for it specifically.

**`Flow#made_count` was deleted as dead.** ADR-0032 removed `fraction_made`, its only reader,
and nothing noticed: twenty-odd writes remained across app and specs, with exactly one reader
— a spec asserting the field round-tripped to itself.

## What this cost, and two things that nearly went wrong silently

**The coverage gate would have passed vacuously.** `spec/spec_helper.rb` selected scheduler
files by the substring `"/app/scheduler/"` and then did `unless scheduler.empty?`. After the
move that matched nothing, so the 100% gate would have been skipped entirely — a green build
enforcing nothing, behind a comment ("what let this ship before the scheduler existed") that
read as intentional. The hook was **deleted**, not repointed, and replaced inside the gem by
SimpleCov's own `minimum_coverage line: 100, branch: 100`. The hand-rolled version only ever
existed because SimpleCov has no *per-directory* minimum and the scheduler was one strict
directory inside a 90% project; now the whole package is the strict part, so the built-in
suffices — and unlike the hook, it cannot silently match nothing.

**The Docker build broke, invisibly to `rspec`.** Both gem-installing stages `COPY Gemfile
Gemfile.lock` and run `bundle install` *before* `COPY . .`, so a path gem's gemspec is absent
when bundler needs it: `The path /rails/gems/deficit_scheduler does not exist`. This reddens
the `cluster` and `images` jobs while the `ruby` job stays green. Fixed by copying the gemspec
ahead of `bundle install` in both stages, which is also why the gemspec hardcodes its version
and globs its files rather than shelling out to `git ls-files` — at that point in the build,
nothing else exists.

**Two duck-typed call sites broke across the new boundary.** `ProjectEta#prep_seconds_for` was
called with both an `OrderItem` and a scheduler item, working only because the two types
happened to share the name `prep_seconds`. It now takes the value rather than the object, so
the caller — which knows what it is holding — resolves it. `Simulator::Projection` had the
same latent coupling. Both are exactly the sort of accidental dependency the extraction was
meant to surface, and neither was visible until the rename removed the coincidence.

## Consequences

Adding a dependency to the scheduler is now a deliberate, visible act in a gemspec rather than
an `include` nobody notices. Mutation testing and the strict coverage gate follow the code.

The cost is a mapping table that must stay in step with two vocabularies. That is guarded
rather than trusted: `spec/services/build_scheduler_config_spec.rb` asserts `KEY_MAP` is total
in both directions — every §6.6 setting reaches a key the scheduler reads, and every key the
scheduler reads is fed by something in `Store::SCHEDULER_DEFAULTS` — plus a round-trip check
that catches a mis-wired-but-still-total entry. A key added to either side without the other
cannot merge.

The gem is named `deficit_scheduler` but its constant is `DeficitScheduler`, and it is not
published. If it ever is, revisit the namespace and add a CHANGELOG; until then the root
`CHANGELOG.md` covers it.

`bin/rspec` at the root no longer runs the scheduler's specs. They run from the gem directory,
as their own CI step, so their SimpleCov root and 100% gate apply cleanly — two SimpleCov
roots cannot both be measured in one process, and the gem's stricter gate is the one that
would have been lost. The gem's spec files use `require_relative "spec_helper"` rather than
`require "spec_helper"`, because mutant and CI invoke rspec from the repo root, where the bare
name resolves to the *application's* helper instead.

## Revisit when

The scheduler is wanted outside this repository, or the portfolio argument in #62 becomes
concrete enough to justify publishing. Both are now small steps rather than a rewrite: the
package is self-contained, its suite runs standalone, and its README carries the reasoning the
`§` citations used to point at.

# ADR-0002: Quality gates — coverage, mutation testing, generated API docs

- **Status:** Accepted
- **Date:** 2026-08-06
- **Design reference:** DESIGN.md §11 (testing), §9.1 (API surface)

## Context

§11 specifies *what* to test but not what enforces it. Three gaps:

1. **Coverage without enforcement is a number nobody reads.** §11 demands a specific list
   of scheduler cases; nothing stops those from rotting into a stale checklist.
2. **The scheduler is the one place where coverage lies.** `pick_next` (§6.2) is pure,
   fast, and mandated to be exhaustively tested — which is exactly the profile where 100%
   line coverage is trivially achievable by tests that assert nothing. A test that calls
   `pick_next` and checks it doesn't raise covers every branch and catches no bug.
3. **Hand-written API docs drift.** §9.1 lists 14 endpoints. Any prose copy of that list
   is wrong within a month.

## Decision

**Coverage** — SimpleCov, enforced in-process so a shortfall fails `rspec` directly rather
than in a separate CI step that can drift from the config:

```ruby
SimpleCov.minimum_coverage line: 90
SimpleCov.minimum_coverage_by_file line: 80
# app/scheduler/** additionally gated at 100% line and branch
```

**Mutation testing on `app/scheduler/**` only.** Not the whole app — mutation testing is
slow and most Rails code isn't worth it. The scheduler is pure, has no I/O, and runs in
milliseconds, which makes it the rare code where mutation testing is both cheap and
meaningful. A surviving mutant (flip `>=` to `>` in the deficit check, delete the
`flow.deficit -=` line) is direct evidence that a §11 case is asserted too weakly.

*Blocked on repository visibility.* Mutant's license is free for public repositories and
commercial for private ones. This repo is currently private, so mutation testing is
**deferred, not dropped** — see "Revisit when."

**Generated API docs** — rswag. Request specs produce `docs/api/openapi.yaml`. The
documentation is the test suite, so it cannot drift from the endpoints it describes.
`docs/api/` is generated output and is never hand-edited.

**Git hooks** — lefthook (`lefthook.yml`): conventional-commit validation on `commit-msg`,
rubocop/eslint autocorrect and a secret-file guard on `pre-commit`. Catching a lint failure
locally costs seconds; catching it in CI costs a round trip.

**The §11 checklist ships as pending specs.** At build step 5, all nine cases are committed
as `it "..." do; skip("not yet implemented"); end`. RSpec output then reports the gaps on
every run. A checklist in a markdown file goes stale silently; a pending spec does not.

## Alternatives considered

| Option | Why not |
|---|---|
| Coverage gate as a separate CI step | Two sources of truth for the threshold. In-process SimpleCov fails the same way locally and in CI. |
| Mutation testing across the whole app | Runtime measured in hours, and most findings would be in controller and serializer code where the mutants are uninteresting. |
| `mutest` (MIT fork of mutant) to sidestep licensing | Substantially less maintained. Taking on an unmaintained dependency to avoid a decision about repo visibility is the worse trade. |
| Hand-written OpenAPI spec | Drifts. Also duplicates §9.1, which already lists the surface. |
| Committing the §11 list only as prose | Already exists in `docs/testing.md`. The pending specs are what make it fail loudly. |
| Husky / raw `.git/hooks` | lefthook is a single binary, config in one committed file, and handles the staged-file plumbing correctly. |

## Consequences

The gates are real: a PR that drops coverage or writes a non-conventional commit message
fails without anyone remembering to check. The cost is that `rspec` now has an opinion
about coverage, which is mildly annoying during exploratory work — use `--no-coverage`
locally when spiking, never in CI.

Deferring mutation testing means the 100% scheduler coverage gate is, for now, weaker than
it reads. Treat it as necessary but not sufficient until mutant is running.

## Revisit when

- **Mutation testing:** when the repo goes public, or when the scheduler lands (§12 step 5)
  and the licensing question needs an answer either way. Whichever comes first.
- **Coverage thresholds:** if the 90% floor starts driving tests written for the number
  rather than for the behavior, lower it and lean harder on mutation testing.

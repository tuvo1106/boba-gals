# Testing conventions

The design's central claim — *a large order must not block small orders* (§2) — is a
claim about behavior under load. It is only true if it is tested. This document says how.

## Layout

```
spec/
  factories/                  FactoryBot definitions, one file per model
  scheduler/                  Pure-function specs. No DB, no Rails. Milliseconds.
    golden/                   Fixed-seed dispatch sequences (committed fixtures)
  models/                     Validations, scopes, state machine transitions
  services/                   Service objects (ClaimNextDrink, RecomputeEta, …)
  requests/                   API endpoints — the real contract
  channels/                   ActionCable subscription auth + payload shape
  jobs/                       Sidekiq workers
  system/                     End-to-end, sparingly (see below)
  support/                    Shared helpers, matchers, config
frontend/src/
  **/*.test.tsx               Vitest + React Testing Library, colocated
```

## The pyramid, and where we deliberately deviate

Most of the value is in **scheduler unit tests** and **request specs**. System specs are
slow and flaky; write them only for flows where the integration *is* the risk (kiosk
place-order → KDS start → board update).

The scheduler is the exception to "don't over-test." It is pure, fast, and load-bearing.
Test it exhaustively.

## Coverage gates

Enforced by SimpleCov in CI. A PR that drops below fails.

| Scope | Line | Branch |
|---|---|---|
| Overall | 90% | — |
| `app/scheduler/**` | 100% | 100% |
| `app/services/**` | 95% | — |

Coverage is a floor, not a goal. 100% coverage of the scheduler with no starvation test
is worthless. The §11 checklist below is what actually matters.

## Required scheduler cases (§11)

Every one of these must exist as a named example before DRR ships. Do not merge the
scheduler with any of them missing.

- [ ] One 15-drink order + one 1-drink order arriving 10s later → the single drink
      dispatches within one quantum.
- [ ] Continuous stream of 1-drink orders + one 20-drink order → the large order still
      completes; assert no starvation.
- [ ] A remake outranks all same-age normal work.
- [ ] An older remake outranks a newer remake.
- [ ] An order with `promised_at` two hours out is not eligible until its
      backward-scheduled start (§6.2 `eligible?`).
- [ ] Cohesion: an order past 50% completion outranks an equal-age order at 0%.
- [ ] An empty queue returns `nil` and never raises.
- [ ] The livelock guard trips rather than spinning.
- [ ] FIFO policy produces strict `queued_at, id` order (the §6.3 control arm).

## Concurrency

`ClaimNextDrink` (§8) needs a real threaded test, not a mocked one:

```ruby
threads = 8.times.map { Thread.new { ClaimNextDrink.new.call(station:, barista:) } }
claimed = threads.map(&:value).compact
```

Assert: every drink claimed exactly once, no duplicates, no exceptions surfaced.

Tag these `:no_transaction` (see `spec/support/concurrency.rb`). Transactional fixtures
wrap each example in one connection's transaction, so other threads cannot see the
uncommitted rows and the contention `SKIP LOCKED` exists to resolve never happens — the
test passes while proving nothing. The tag swaps in truncation cleanup instead, and the
test pool is sized at 16 so threads don't silently serialize.

One trap worth knowing, because it produces a *passing-looking* wrong answer: calling
`.first` on a locked relation replaces your batch limit with `LIMIT 1`, and PostgreSQL
applies `LIMIT` during the scan rather than to the set it successfully locked. A contended
row is skipped after the limit is already spent, so the query returns nothing while
unclaimed drinks sit right behind it. Fetch the batch, then choose in Ruby.

## Golden tests

Fixed seeds producing byte-identical dispatch sequences. They live in
`spec/scheduler/golden/` as committed fixtures.

- They exist so the scheduler can be refactored without fear.
- A diff in a golden file is a **behavior change** and must be justified in the PR body.
  Never regenerate them to make a red build green.
- If the simulator is ever implemented client-side (§10.1 option B), 20 golden scenarios
  asserting Ruby and TypeScript agree become mandatory.

## Acceptance criteria (§11)

These are simulation-backed properties, run as a slow-tagged suite (`--tag acceptance`),
not on every push:

- Small-order p90 wait is flat (±15%) across large-order rates 0%–12%, under DRR, at 3
  stations, default demand.
- The same test under FIFO shows a clearly rising line. *If it doesn't, the generative
  model isn't stressing the system* — fix the model, don't relax the assertion.
- ETA bias converges within ±45s after 200 simulated orders with EWMA enabled.

## FactoryBot conventions

- One factory per model in `spec/factories/<plural>.rb`.
- Factories build the **minimum valid object**. Everything else is a trait.
- Traits are named for the state they produce: `:queued`, `:in_progress`, `:remake`,
  `:large_order`, `:promised`.
- Prefer `build` and `build_stubbed` over `create`. Hitting the DB is a choice.
- No `create_list(:order, 50)` in a `before` block. If a spec needs a busy store, use a
  named helper that makes the intent legible: `busy_store(orders: 50)`.
- Sequences for anything unique (`pickup_code`, `email`). Never hardcode.
- `FactoryBot.lint` runs in CI — every factory and trait must produce a valid record.

## Time

Never `sleep`. Use `ActiveSupport::Testing::TimeHelpers` (`travel_to`, `freeze_time`) in
Rails specs. In scheduler specs the clock is an injected argument — just pass a `Time`.

## Determinism

Every simulation-touching spec seeds its RNG explicitly and prints the seed on failure.
A flaky test is a bug in the test; quarantine it, don't retry it.

## Frontend

- Vitest + React Testing Library, tests colocated with components.
- Query by role and accessible name. `data-testid` is a last resort.
- Mock at the network boundary (MSW), never by stubbing component internals.
- The kiosk offline state (§9.3) and the board's 90-second pickup persistence (§9.5) are
  behaviors with real failure modes — test them.

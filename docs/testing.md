# Testing conventions

The design's central claim — *a large order must not block small orders* (§2) — is a
claim about behavior under load. It is only true if it is tested. This document says how.

## Layout

```
spec/
  factories/                  FactoryBot definitions, one file per model
  models/                     Validations, scopes, state machine transitions
  services/                   Service objects (ClaimNextDrink, RecomputeEta, …)
  requests/                   API endpoints — the real contract, and rswag's source
  serializers/                Response shapes
  channels/                   ActionCable subscription auth + payload shape
  jobs/                       Sidekiq workers
  simulator/                  §10 experiments — read the cost rules below first
  config/                     Design invariants that no unit test would catch
  support/                    Shared helpers, matchers, config
gems/deficit_scheduler/spec/  Pure-function specs. No DB, no Rails. Milliseconds.
  golden/                     Fixed-seed dispatch sequences (committed fixtures)
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

| Scope | Line | Branch | Enforced by |
|---|---|---|---|
| Overall | 90% | — | `minimum_coverage` in `spec/spec_helper.rb` |
| `gems/deficit_scheduler` | 100% | 100% | `minimum_coverage line: 100, branch: 100` in the gem's own `spec/spec_helper.rb` |

Both fail `rspec` in-process rather than in a separate CI step, and the overall gate is
skipped on a partial run (`bin/rspec spec/models`) because a subset cannot meet a
whole-project floor.

The scheduler gate runs in the gem's **own** suite, not the root one (ADR-0033): two
SimpleCov roots cannot both be measured in one process.

Two gates in this table's history looked armed and were not, which is why the rule is now
*add the check first and the row second*. The root `at_exit` hook selected files by the
substring `"/app/scheduler/"` and skipped itself when nothing matched, so the gem extraction
would have left it green while enforcing nothing — it was deleted, not repointed. And an
earlier row claimed 95% on `app/services/**` that nothing enforced at all. Services are
covered by the overall floor.

Coverage is a floor, not a goal. 100% coverage of the scheduler with no starvation test
is worthless. The §11 checklist below is what actually matters.

## Required scheduler cases (§11)

Every one of these must exist as a named example before DRR ships. Do not merge the
scheduler with any of them missing.

- [x] One 15-drink order + one 1-drink order arriving 10s later → the single drink
      dispatches within one quantum.
- [x] Continuous stream of 1-drink orders + one 20-drink order → the large order still
      completes; assert no starvation.
- [x] A remake outranks all same-age normal work.
- [x] An older remake outranks a newer remake.
- [x] An order with `promised_at` two hours out is not eligible until its
      backward-scheduled start (§6.2 `eligible?`).
- [x] Cohesion: an order past 50% completion outranks an equal-age order at 0%.
- [x] An empty queue returns `nil` and never raises.
- [x] The livelock guard trips rather than spinning.
- [x] FIFO policy produces strict `queued_at, id` order (the §6.3 control arm).

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

## Redis

The suite talks to a real Redis, not a fake. The board's broadcast throttle is a
`SET NX PX` lock whose entire purpose is to behave correctly across two `web` pods
(§14.4) — a stub would assert that the code calls Redis, which is not the property worth
testing. `spec/support/redis.rb` aborts with instructions if it can't connect.

Keys are namespaced per environment by `BobaGals.redis_key`, the same way ActionCable
namespaces its channels, so a test run cannot disturb the development keyspace.

Do not `sleep` through a Redis TTL. Assert the TTL exists, or delete the key to simulate
expiry — see `spec/services/board_broadcast_spec.rb`.

## Mutation testing

```bash
COVERAGE=0 bundle exec mutant run          # the whole scheduler — ~22s
COVERAGE=0 bundle exec mutant run -- 'DeficitScheduler.quantum_for'  # one subject
bundle exec mutant session subject 'DeficitScheduler#validate!'      # survivors, after a run
```

Config is `config/mutant.yml`; `config/mutant_boot.rb` loads the scheduler **without
Rails**, which is both faster and a check that the §6.2 purity rule still holds.

`COVERAGE=0` matters — SimpleCov's at-exit gate would otherwise run inside every one of the
hundreds of forked mutant processes.

Score: **89.69%** — 940 of 1048 killed, 108 alive, 8 timeouts. Measured 2026-08-15 on the
host (not in the container), **22.4 seconds** wall clock at 10 jobs.

The first run of the day scored 89.40%; #114 closed three survivors in `quantum_for`. It is
still *down* from the 93.14% recorded on 2026-08-07 (#14), and the reason is worth knowing:
that score was against **788** mutations. The gem has grown to **1048**, so ~260 mutations
had never been evaluated, and the newer code — `Config#validate!`, `Config.from_h`, and the
`Flow`/`Item`/`State` constructors — carries most of the survivors. SimpleCov reports the gem
at 100% line and branch the whole time, which is exactly the point of running this at all.

Do not chase 100%. The survivors are
equivalent mutants — `guard = 0` → `1` against a 10,000-iteration limit, `0` → `-1` in a
sort tier where both sort below 1 — plus default-argument removals no caller exercises.
Killing those means writing tests that assert nothing anyone cares about.

What to do with a *new* survivor: read it as a question. "Would a barista notice if this
changed?" If yes, it is a missing test. If no, it is equivalent and should be left alone.

## What a simulation spec is allowed to cost

Every simulated arrival runs a forward projection through `DeficitScheduler.pick_next` (§7.1),
so a
simulated day is not free and a saturated one is expensive. Profile before optimising —
`bin/rspec --profile` — because the cost is never spread evenly. It concentrated in twelve
examples once, at 84% of the whole suite.

Two rules fell out of that, and both make the assertion sharper rather than weaker:

- **Stub the ceiling, don't run to it.** Two examples asserted that a request above
  `Ablation::MAX_SEEDS` is clamped by simulating 300 and 150 days. `stub_const` to 2 tests
  the same `clamp` in a tenth of the time, and no longer passes by coincidence of the
  constant's value — which then gets its own one-line assertion.
- **Buy saturation with demand, not with hours.** A property that needs a backed-up shop
  needs the shop to be *over capacity*, which is a ratio, not a duration. One station at
  3.0× is saturated inside the first hour: four hours separated the multi-drink breach rate
  from the overall rate more widely than eleven did (0.399 vs 0.288, against 0.353 vs
  0.261), in a tenth of the time.

Neither is licence to lower a threshold or skip a case to make a red suite green. The test
is that the numbers still say what they said — check coverage is unchanged, and that the
margin on the assertion got wider rather than narrower.

**A third rule, once the first two stopped being enough (issue #75).** By the time four
§10.5 experiments each had their own spec file, `bin/rspec` had grown from seconds to 5m33s
locally and 17+ minutes in CI — not from any one file, but from the same shape repeating:
a "narrowed" context that was narrow in *range* but not in *cost* (a low station or drink
count is itself expensive at this file's realistic demand — 1 station at 1.6x demand costs
3.16s against 0.14s at 3, a 22x difference that narrowing the count alone does not fix), and
request specs that never stubbed anything at all, paying full simulation cost just to
exercise routing and response shape.

**Tag a real-parameter example `:slow` rather than deleting the coverage it earns.**
`spec/spec_helper.rb` excludes `:slow` by default; `SLOW=1 bin/rspec` runs everything,
including every `:slow` example. Two commands, not two suites to keep in sync:

```bash
bin/rspec                              # fast tier — CI, every push
SLOW=1 bin/rspec                       # both tiers — before a release, or touching app/simulator/**
SLOW=1 bin/rspec spec/simulator/staffing_curve_spec.rb   # one file's slow examples
```

What earns the tag: an example that needs the *real* range, the *real* demand, or enough
pooled days to trust a noisy statistic — the ones the first two rules above cannot make
cheap without changing what's being proven. Everything else gets the existing two rules
applied harder: stub the swept constant small **and** drop demand to whatever a mechanism
check (clamping, reproducing, falling back) doesn't depend on the realism of — narrowing
only the *count* while leaving demand realistic was the gap that let `staffing_curve_spec.rb`
back up to 108.98s despite already having a "narrowed" context.

That work cut the default tier from 333s to 77s locally without moving the coverage gates.
§11's acceptance suite, when it exists, is the next candidate for `:slow` rather than a
bespoke `--tag acceptance` mechanism.

## Golden tests

Fixed seeds producing byte-identical dispatch sequences. They live in
`gems/deficit_scheduler/spec/golden/` as committed fixtures.

- They exist so the scheduler can be refactored without fear.
- A diff in a golden file is a **behavior change** and must be justified in the PR body.
  Never regenerate them to make a red build green.
- Regenerate deliberately, and read the diff before committing it:

  ```bash
  cd gems/deficit_scheduler && REGENERATE_GOLDEN=1 bundle exec rspec spec/golden_spec.rb
  ```

- **A fixture that cannot differ from another fixture is pinning nothing.** Both of these
  shipped vacuous on the first attempt and were caught by deliberately breaking the
  behaviour they claimed to cover: `cohesion_enabled` came out byte-identical to
  `mixed_day`, because every generated flow starts at `made_count: 0` and cohesion can never
  fire; and the `remakes` fixture survived deleting §6.4's priority floor entirely, because
  those flows already sort first on the 4x remake multiplier. Each scenario needs the thing
  it names to be the thing that decides the order.
- Prove a new fixture is armed the same way any other guard is: break the rule it covers,
  confirm *that* fixture fails, restore.
- If the simulator is ever implemented client-side (§10.1 option B), 20 golden scenarios
  asserting Ruby and TypeScript agree become mandatory.

## Acceptance criteria (§11) — not yet built

**No acceptance spec exists yet.** These are §11's simulation-backed properties, and the tag
to reach for when they're written is the `:slow` mechanism above — pooling enough days to
trust a ±15% or ±45s tolerance is exactly the "real parameter, real cost" case it exists for.
Written down here as a target rather than a description of something that runs — the ETA
bias figure the third one needs only started existing with §10.4's metric grid:

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
- Mock at the network boundary (MSW), never by stubbing component internals. The server is
  set up in `src/test/server.ts` and started by `src/test/setup.ts` with
  `onUnhandledRequest: 'error'` — a component calling an endpoint no test declared is
  either a bug or an untested path, and both deserve a failure rather than a warning.
- ActionCable is the exception: jsdom has no server to talk to, so `src/api/cable.ts` is
  mocked with `vi.mock` and the test pushes broadcasts through the captured handler. The
  subscription plumbing is covered by the Rails channel specs instead.
- The kiosk offline state (§9.3) and the board's 90-second pickup persistence (§9.5) are
  behaviors with real failure modes — test them.

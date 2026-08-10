# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A boba shop ordering + kitchen scheduling system. Rails 8 API + React 19 (TypeScript),
PostgreSQL, Redis, Sidekiq, deployed to Kubernetes.

**`DESIGN.md` is the specification and the source of truth.** It is section-numbered
(`§6.2`, `§14.4`, …). Read the relevant sections before implementing anything.

### Non-negotiables from the design

These are decided. Do not relitigate them in code, comments, or PR discussion:

- **Schedule drinks, not orders.** `OrderItem` is the unit of work (§2).
- **No Rails 8 "Solid" defaults, no Kamal.** Redis is load-bearing; Sidekiq for jobs (§ Rails 8 note, §14.1).
- **`Scheduler.pick_next` is a pure function** — no ActiveRecord, no `Time.now`, no I/O.
  The simulator runs the production scheduler unmodified (§6.2, §10.1).
- **The locked decisions table (§3)** — kiosk refuses orders offline, remakes get a priority
  floor, board shows first name + code only, quality timer ships, simulation is in-app.
- **`customer_phone` never leaves the server** except to Twilio (§13.5).

If a design decision looks wrong while implementing, say so and stop — don't silently
deviate. Changing the design means editing `DESIGN.md` in its own PR.

## This repository is public

Everything here is world-readable: the code, **the full git history**, PR bodies, issues,
and Actions logs. Write accordingly.

**Never commit a secret.** Not a key, token, password, connection string, or customer
record — not "temporarily", not in a branch you plan to squash. The `no-secrets` lefthook
guard matches known *filenames*; it does not read values, and it will not save you.

Where real secrets actually live:

| Secret | Home |
|---|---|
| `DATABASE_URL`, `REDIS_URL`, `RAILS_MASTER_KEY`, `SEED_ADMIN_PASSWORD`, later `TWILIO_*` | k8s Secret, created out of band (§14.6) |
| Anything encrypted | `config/credentials.yml.enc` — safe only because `config/master.key` has never been committed and must never be |
| Local overrides | `.env`, gitignored |

Credential-shaped strings **are** committed in a few places, deliberately, and every one of
them says so in its own value: `dev-only-not-a-real-password`, `SECRET_KEY_BASE=dev000…dev`,
`changeme-in-any-real-deploy`, barista PIN `1234`. All are scoped to a kind cluster that
gets deleted. Keep that convention — a fake credential should be unmistakable from the value
alone, without reading the surrounding comment.

**If a secret does land in a commit, rotate it first.** Deleting it in a later commit
achieves nothing: the blob stays reachable by SHA, GitHub caches it, and forks and clones
keep it forever. Rotate, then rewrite history, in that order. Treat it as compromised the
moment it is pushed.

Two consequences that are easy to forget:

- **Actions logs are public.** Don't `echo` environment variables or paste real data into a
  workflow step. Diagnostic steps that dump `kubectl describe` output are fine; ones that
  dump a Secret are not.
- **PR bodies are public.** The "Verified by hand" transcripts this project asks for must
  never contain a real `customer_phone` (§13.5) or any other customer data. Seeded demo
  values only.

## Working agreements

### Every major feature ships as a PR

One PR per feature, sized to a single **build step** (§12) or a coherent slice of one.
Never commit directly to `main`.

```
git checkout -b step-05-scheduler-pure-function
```

Branch naming:

| Prefix | Use |
|---|---|
| `step-NN-<slug>` | Work that maps to a §12 build step |
| `feat/<slug>` | Feature not tied to a build step |
| `fix/<slug>` | Bug fix |
| `chore/<slug>` | Tooling, deps, CI |
| `docs/<slug>` | Docs only |

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):
`feat(scheduler): add deficit round robin dispatch`. Scopes: `scheduler`, `kds`, `board`,
`ordering`, `sim`, `api`, `web`, `k8s`, `ci`, `docs`. Enforced by a `commit-msg` hook —
run `lefthook install` once after cloning.

PRs use `.github/pull_request_template.md`. It is not optional — fill every section, and
delete none. The **Design reference** line must cite the `§` sections the PR implements.

### Definition of done

A PR is not done until all of these are true:

1. Tests pass and coverage gates hold (see below).
2. `CHANGELOG.md` has an entry under `## [Unreleased]`.
3. Public classes and methods have YARD doc comments (see below).
4. Any decision *not* already in `DESIGN.md` is captured as an ADR in `docs/adr/`.
5. New env vars, migrations, or manifests are listed in the PR's **Ops** section.
6. `bundle exec rubocop` and `npm run lint` are clean.

## Testing

Full conventions: `docs/testing.md`. The short version:

- **RSpec** for Rails, **FactoryBot** for fixtures. No `fixtures/`, no `let!` chains that
  build the world — build only what the example needs.
- **Vitest + React Testing Library** for the frontend.
- Coverage gates (SimpleCov, enforced in-process so `rspec` itself fails — see ADR-0002):
  - Overall line coverage **≥ 90%**
  - `app/scheduler/**` — **100% line and branch.** This is the load-bearing code and it is
    pure, so there is no excuse.
- The §11 scheduler test list is a **required checklist**, not a suggestion. Ship it as
  pending specs (`skip "not yet implemented"`) so RSpec reports the gaps on every run, and
  every case must be a real named example before DRR merges.
- **Mutation testing** (`mutant`) covers `app/scheduler/**` only. 100% coverage on a pure
  function proves nothing on its own — a surviving mutant is the real signal. ADR-0002
  deferred this until the repo went public *or* the scheduler landed; both are now true, so
  it ships with build step 5. Nothing left to defer it behind.
- **Golden tests** (fixed seed → byte-identical dispatch sequence) live in
  `spec/scheduler/golden/`. Regenerate them deliberately, never casually — a changed
  golden file must be explained in the PR body.
- Write the test that would have caught the bug before fixing the bug.

### Reproducing a flake

**Narrow the code's timing, never widen the machine's load.** To reproduce a race that only
fails on CI, shrink the constant that governs it — a retry budget, a timeout, a batch size —
until the failure is deterministic, then restore it. That isolates the mechanism and runs in
seconds.

Do **not** generate synthetic load on the dev machine. It was tried here: twelve busy-wait
loops reproduced a `ClaimNextDrink` flake zero times in fifteen minutes, while setting
`MAX_ATTEMPTS = 1` reproduced it ten times out of twelve, immediately, and named the cause.
The loops also outlived their cleanup — backgrounded processes reparent to PID 1, so
`jobs -p` in a non-interactive shell does not find them — and sat at 100% CPU until noticed.

Any background process must be cleaned up by explicit PID, and the cleanup verified rather
than assumed.

### Killing a command does not kill what it started

**Interrupting `docker compose exec` kills the client, not the process in the container.**
The exec session goes away; whatever it launched keeps running, detached, with nothing
attached to notice. Same for anything that forks workers — `mutant` is the one that has
actually bitten here.

It happened on 2026-08-09: an interrupted `mutant run` left `mutant-ruby` plus eleven
`mutant-worker-process-*` alive, holding the `api` container at **359% CPU** until the
laptop's fans gave it away. Nothing on the host's process list showed it, because the
processes were inside the container.

So:

- **Never start `mutant` from a session.** It runs the whole suite once per mutant, forks a
  worker per core, and takes tens of minutes. It is a CI-shaped job. If a mutation score is
  needed, ask for it to be run deliberately, or read the last recorded figure.
- After interrupting *any* long container command, check before moving on:

  ```bash
  docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}'
  docker compose exec api ps -eo pid,pcpu,args     # then kill -TERM by explicit PID
  ```

  An idle stack sits near 0%. Anything sustained above ~50% with no command attached is an
  orphan, and `docker compose restart <service>` is the blunt fix.
- Prefer a bounded run over an open-ended one: `timeout N docker compose exec …` puts a
  ceiling on the damage a forgotten command can do.

### Restoring a file you broke on purpose

Proving a guard is armed means breaking the invariant, watching the specific spec fail, and
putting the file back. **Copy it to a scratch path first and restore from that copy.**

Do not restore with `git checkout <path>`. Most of this work happens with a tree full of
uncommitted changes, so that reverts to the last commit and takes everything unstaged with
it — it once wiped sixty lines of unstaged work in `app/simulator/simulator.rb` while undoing
a one-line `perl -pi` edit. Restore by `cp`, then grep for a distinctive line from your change
to confirm the restore rather than assuming it. Breaking several files means backing up each
one, not just the first.

### Check the frontend the way CI does

```bash
npm --prefix frontend run lint       # oxlint
npm --prefix frontend run typecheck  # tsc -b --noEmit
npm --prefix frontend run test:run   # vitest, once
```

**Never verify with a bare `npx tsc --noEmit`.** The repo's script is `tsc -b` — build mode,
which walks the project references and typechecks the *test* project. Plain `tsc --noEmit`
skips it and returns 0 while a `*.test.tsx` fixture is broken. CI runs `tsc -b` twice, in the
frontend job and again inside the image build in the cluster job, so one such miss turns two
jobs red. A `pre-push` hook now runs `typecheck`, but the hook is a backstop, not the habit.

Adding a required field to a shared type in `frontend/src/api/types.ts` means every
hand-built fixture of that type needs it. Grep the test files for the type name rather than
trusting one suite run.

Run:

```bash
bin/rspec                    # Rails suite
bin/rspec spec/scheduler     # scheduler only — should finish in milliseconds
npm --prefix frontend test   # frontend
```

## Documentation

Documentation is part of the change, not a follow-up.

These are non-overlapping. If you're about to write something down, it goes in exactly one:

| Where | What goes there |
|---|---|
| `DESIGN.md` | The specification. Edit only in a dedicated PR that changes nothing else — except §17, see below. |
| `DESIGN.md` §17 | Glossary. **Appending a definition is exempt from the dedicated-PR rule.** |
| `docs/adr/` | Decisions made *during* implementation that DESIGN.md doesn't cover, or that contradict it (which also updates DESIGN.md). |
| `docs/testing.md` | Test strategy and conventions. |
| `docs/api/` | Generated by rswag from request specs — **never hand-edit**. |
| Code comments | Why, not what. Cite `§` sections for design-mandated behavior. |
| `README.md` | Getting started, nothing else. |

### Keep the glossary current

**If a PR introduces a term a competent engineer outside this domain would have to look up,
define it in §17 in that same PR.** Queueing theory and networking supply most of them —
deficit, quantum, flow, ρ, Kingman, Poisson, thinning, lognormal, heavy-tailed, balking,
Little's Law were all in the document before any of them were defined.

This is the one DESIGN.md edit that does not need its own PR — and it should not get one.
Appending a definition explains the specification rather than changing it, and splitting it
out means the term lands in a different PR from the code that introduced it, which is how a
glossary rots. *Changing* an existing definition is a different act and follows the normal
rule.

The trigger is deliberately low: if you had to look it up, or you find yourself writing a
parenthetical gloss in a code comment, that is the signal. The repository is public, and §6.1
sat at 91 words assuming every reader knew what deficit round robin was.

Write an ADR when a decision is hard to reverse, non-obvious to the next reader, or was
reached by rejecting a plausible alternative. Routine Rails choices don't need one.
ADRs are immutable once accepted — supersede, don't edit.

YARD comments on every public class and method. For anything implementing a design
decision, cite the section:

```ruby
# Picks the next drink to dispatch using Deficit Round Robin over orders (DESIGN.md §6.1).
#
# Pure function: no ActiveRecord, no clock access, no I/O — the simulator (§10.1) calls
# this exact method with a SimClock.
#
# @param state [Scheduler::State] flows, ring pointer, and config
# @param now [Time] injected clock reading
# @return [Hash{Symbol => Object}, nil] `{ flow:, item: }`, or nil when nothing is dispatchable
def pick_next(state, now)
```

## Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/). Every PR adds a
line under `## [Unreleased]` in the right category (`Added`, `Changed`, `Fixed`,
`Removed`, `Deprecated`, `Security`). Write it for someone operating the shop, not for
someone reading the diff:

```
### Added
- Kitchen display shows a "Next up" section of the 3 upcoming drinks so baristas can
  pre-stage cups and toppings (§9.4).
```

## Style

- Match the surrounding code. Rails conventions where Rails has one.
- Service objects are single-public-method classes in `app/services/`, named as verbs
  (`ClaimNextDrink`, `RecomputeEta`).
- The scheduler core lives in `app/scheduler/` as plain Ruby — **it must not require
  Rails to load.** If you find yourself reaching for `Time.current` there, inject a clock.
- No broadcasts, jobs, or HTTP calls inside a database transaction. Use `after_commit` (§8).
- Frontend: function components, hooks, no class components. TypeScript strict mode.

## Things that will bite you

- Two `web` pods run from the start (§14.2). Any in-process state is a bug — the ETA
  debounce must be the Redis `SET NX PX` lock (§7.2, §14.4).
- `finished` is terminal for an `OrderItem`. Remakes create new rows. The only exception
  is the 60s KDS undo, which must also discard the prep-time sample (§5.2).
- Never run migrations on container boot — that's the `migrate` Job's task (§14.2).

# Boba Gals

Ordering and kitchen scheduling for a boba tea shop. Rails 8 API + React 19,
PostgreSQL, Redis, Sidekiq, deployed to Kubernetes.

The central constraint: **a large order must not block small orders.** Drinks are
scheduled individually via deficit round robin, so a customer ordering one drink
behind a 15-drink catering order waits roughly one drink's time.

**[`DESIGN.md`](DESIGN.md) is the specification** — it is section-numbered and is the
source of truth for every decision here.

## Setup

Requires [Docker](https://docs.docker.com/get-started/) and
[mise](https://mise.jdx.dev/) (or any version manager that reads `.ruby-version`
and `.node-version`).

```bash
mise install                 # Ruby 3.4.10, Node 24.19.0
bundle install
npm --prefix frontend install
lefthook install             # commit-msg + pre-commit hooks

docker compose up -d postgres redis
bin/rails db:prepare
```

If `ruby -v` still reports the system Ruby, mise isn't activated in your shell:

```bash
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc                          # interactive shells
echo 'export PATH="$HOME/.local/share/mise/shims:$PATH"' >> ~/.zprofile # hooks and editors
```

## Running

```bash
docker compose up            # postgres, redis, api :3000, worker, vite :5173
```

`api` and `worker` run the same image with different commands — the production
topology (§14.1), rehearsed locally so it isn't discovered at deploy time.

## Tests

```bash
bin/rspec                    # full suite; coverage gates enforced
bin/rspec spec/requests      # partial run; gates skipped
COVERAGE=0 bin/rspec         # no instrumentation, for spiking
bundle exec rubocop

npm --prefix frontend run test:run
npm --prefix frontend run lint
```

Coverage gates (ADR-0002): **90% overall**, and **100% line and branch on
`app/scheduler/**`** once it exists. Both fail `rspec` directly rather than in a
separate CI step.

## Layout

| Path | |
|---|---|
| `app/scheduler/` | The DRR scheduler (§6). Pure Ruby — must not require Rails. |
| `frontend/` | One React build serving kiosk, web, KDS, board, and dashboard (§9.3). |
| `spec/scheduler/` | Pure-function specs. No DB, no Rails, milliseconds. |
| `docs/adr/` | Decisions made during implementation. |
| `docs/testing.md` | Test conventions and the §11 scheduler checklist. |
| `CLAUDE.md` | Working agreements — branches, commits, definition of done. |

## Build order

Follow §12. Steps 1–3 give a shop that functions, step 4 puts it in a cluster so
every later feature ships through Kubernetes, and steps 5–6 are where the design's
central claim actually gets tested.

**Current position: step 0 complete** — containers, toolchain, and CI.

Postgres runs in-cluster as a StatefulSet (§14.2), which is instructive for a
learning project and wrong for a real store; that would use a managed database.

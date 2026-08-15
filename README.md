# Boba Gals

Ordering and kitchen scheduling for a boba tea shop.

The central constraint: **a large order must not block small orders.** The unit of
work is a *drink*, not an order, and drinks are scheduled by deficit round robin —
so a customer ordering one drink behind a 15-drink catering order waits roughly one
drink's time, not fifteen.

The full specification is [`DESIGN.md`](DESIGN.md). It is section-numbered, and those
numbers are what the `§6.2`-style references in the code and below point at.

## What this demonstrates

- **A scheduling algorithm, not a CRUD app.** Deficit round robin (Shreedhar & Varghese, 1995)
  with aging, priority tiers, deadline scheduling and a staleness boost — chosen because the
  naive answer, first-in-first-out, makes a one-drink customer wait behind a fifteen-drink
  catering order.
- **The design claim is tested, not asserted.** A discrete-event simulator runs the
  *production* scheduler unmodified against a simulated clock, so "large orders don't block
  small ones" is a measured result — swept across demand, staffing and policy, and charted
  against FIFO, round robin and shortest-job-first as comparison arms.
- **The scheduler is a dependency-free gem.** `pick_next` is a pure function: no database, no
  clock, no I/O. Zero runtime dependencies is the enforcement, not the aspiration.
- **Decisions are written down.** 39 ADRs record what was chosen, what was rejected, and the
  measurements behind it — including the ones that concluded *don't build this*.
- **Tests are held to more than coverage.** The gem is at 100% line and branch, and mutation
  testing still found a hole in a locked design decision; 12 golden fixtures pin byte-identical
  dispatch sequences so the scheduler can be refactored without fear.
- **It actually deploys.** Hand-written Kubernetes manifests with Kustomize overlays, stood up
  on a real cluster by CI on every push — order placed through the ingress, probes checked,
  Redis pulled out from under the pods.
- **The API contract is generated.** OpenAPI from the request specs, TypeScript types from the
  OpenAPI, and CI fails if either drifts from what's committed.

## Stack

| | | Why this one |
|---|---|---|
| **Ruby 3.4** / **Rails 8** | API only — no views, no asset pipeline | The frontend is a separate build; Rails serves JSON and ActionCable |
| **React 19** + **TypeScript** | Kiosk, web ordering, KDS, pickup board, admin dashboard | One bundle, five surfaces (§9.3). Strict mode, function components only |
| **PostgreSQL 16** | Orders, drinks, menu, learned prep times | Partial indexes carry the hot queries; `SKIP LOCKED` history in §12 step 2 |
| **Redis 7** | Scheduler deficits + ring pointer, ETA debounce lock, ActionCable pub/sub, Sidekiq queues | **Load-bearing, not a cache.** Two `web` pods from day one, so coordination cannot live in process (§14.4) |
| **Sidekiq** | ETA recomputes, prep-time learning, quality sweeps, ready SMS | Rails 8's Solid defaults are deliberately *not* used — Redis is already here (§14.1) |
| **Kubernetes** (kind locally) | 2× `web`, 2× `frontend`, `worker`, Postgres, Redis, ingress-nginx | Hand-written manifests + Kustomize overlays; every feature ships through the cluster (§12 step 4) |
| **Vite** / **Vitest** / **oxlint** | Frontend build and test | |
| **RSpec** / **FactoryBot** / **SimpleCov** / **mutant** | Backend test and coverage | Mutation testing is scoped to the scheduler gem — 100% coverage on a pure function proves little on its own |
| **Prometheus** / **Grafana** | Business gauges, not just framework metrics | Queue depth, wait percentiles by order size, ETA error (§15) |

The scheduler itself is a **[path gem with zero runtime dependencies](gems/deficit_scheduler/)**
that does not load Rails. That is the boundary: it cannot quietly reach for
`Time.current` or an ActiveRecord model, because doing so would mean adding a
dependency on purpose (ADR-0033).

## How it fits together

```mermaid
flowchart TB
  subgraph clients["Browser surfaces — one React build"]
    direction LR
    K["Kiosk"]
    O["Web ordering"]
    D["KDS"]
    B["Board"]
    A["Dashboard"]
  end

  IN["ingress-nginx — TLS"]
  FE["frontend ×2"]

  subgraph pod["web ×2 — puma + ActionCable"]
    direction TB
    API["Rails API"]
    GEM["deficit_scheduler<br/>path gem, no Rails"]
    API -- "pick_next" --> GEM
  end

  WK["worker — Sidekiq"]
  PG[("PostgreSQL")]
  RD[("Redis")]

  clients --> IN
  IN --> FE
  IN --> API
  API --> PG
  API --> RD
  WK --> PG
  WK --> RD
  RD -. "pub/sub across pods" .-> API
```

**The scheduler is a gem, and that is the point.** `deficit_scheduler` is a path gem
in this repo with **zero runtime dependencies**, and it does not load Rails. `pick_next`
takes a state snapshot and an injected clock, reads no database and performs no I/O —
which is what lets the simulator (§10) run the *production* scheduler unmodified against
a simulated clock. The gemspec is the enforcement: reaching for `Time.current` or an
ActiveRecord model would mean adding a dependency on purpose (ADR-0033). It speaks
`cost`/`expedited`/`deadline`, not `prep_seconds`/`remake`/`promised_at` — the two
vocabularies meet in exactly one place, `BuildSchedulerConfig`.

Redis carries four unrelated jobs — scheduler state, the ETA debounce lock,
ActionCable pub/sub, and Sidekiq's queues. Only the last is durable; the rest are
reconstructible by design (§6.5), which is why it runs with AOF but the scheduler
tolerates a cold start.

## Key flows

**Placing an order.** The quote a customer sees is produced by running the *real*
scheduler forward over the current queue — not a `total_work / stations` estimate —
so it stays correct when scheduler parameters change (§7.1).

```mermaid
sequenceDiagram
  autonumber
  participant C as Customer
  participant W as Rails (web)
  participant PG as PostgreSQL
  participant R as Redis
  participant KDS as KDS + board

  C->>W: POST /api/v1/orders
  activate W
  note over W,PG: one transaction
  W->>PG: insert Order + OrderItems
  W->>W: ProjectEta — runs the scheduler forward
  W->>PG: save quoted_wait_seconds
  W-->>C: 201 — pickup code + ETA
  deactivate W

  note over W,R: after commit only, never inside the transaction (§8)
  W->>R: publish kitchen view
  W->>R: SET eta_lock NX PX 2000
  alt window was open
    W->>R: enqueue trailing flush (Sidekiq, +2s)
  else first trigger in window
    W->>W: reproject ETAs now
  end
  R-->>KDS: board + kitchen update
```

**Making a drink.** Which drink comes next is decided by a pure function over a
snapshot, with **no database lock held** — the claim is a single conditional
`UPDATE`, so two tablets racing resolve on the row, not on a mutex (§6.2).

```mermaid
sequenceDiagram
  autonumber
  participant T as KDS tablet
  participant W as Rails (web)
  participant R as Redis
  participant PG as PostgreSQL
  participant S as deficit_scheduler

  T->>W: POST /kds/items/start (Bearer station token)
  W->>W: verify token + station still active
  W->>R: load deficits + ring pointer
  W->>PG: load queued drinks
  W->>S: pick_next(state, now)
  note right of S: pure — no clock, no I/O
  S-->>W: { flow, item }
  W->>PG: UPDATE … WHERE status = 'queued'
  alt row already claimed
    PG-->>W: 0 rows — retry with a fresh snapshot
  else claimed
    W->>R: save deficits + pointer
    W-->>T: the drink to make
    W->>R: broadcast kitchen + board
  end
```

**Finishing it.** `finished` is terminal — a bad drink becomes a *new* row, never an
edit — with one exception: a 60-second undo for a mistap, which is why the prep-time
sample is deferred rather than recorded inline (§5.2, ADR-0019).

```mermaid
sequenceDiagram
  autonumber
  participant T as KDS tablet
  participant W as Rails (web)
  participant Q as Sidekiq
  participant C as Customer

  T->>W: POST /kds/items/:id/finish
  W->>W: mark finished, roll up order status
  W->>Q: RecordPrepTime (+60s, after the undo window)
  alt every drink now finished
    W->>Q: SendReadySms
    W->>Q: RecordQualitySpread (+60s)
    Q-->>C: "your order is ready"
  end
  W->>W: broadcast board + order + kitchen
  note over T: Undo stays available for 60s —<br/>and discards the prep-time sample
```

## Design invariants

Five constraints hold across the system. They explain a good deal of why the code is
shaped the way it is, and each is load-bearing rather than stylistic.

- **`finished` is terminal for a drink.** A remake is a new row, never an edit to the old
  one, which keeps prep-time statistics honest and makes remakes visible in reporting. The
  single exception is the 60-second kitchen undo, which also discards the prep-time sample.
- **Redis is infrastructure, not a cache.** It carries cross-pod broadcasts, the board
  throttle, the scheduler's deficits, and Sidekiq's queues — the last of which is why it
  runs with AOF and a persistent volume (ADR-0038).
- **`DeficitScheduler.pick_next` is a pure function** — no database, no clock, no I/O. That
  is what lets the simulator run the production scheduler unmodified against a simulated
  clock, and the gem's zero runtime dependencies are what keep it that way.
- **`web` runs at least two replicas.** In-process state would work on one and diverge on
  two, so there is none.
- **Migrations never run on container boot.** A dedicated Job owns them, applied before each
  rollout.

## Where things live

A map from the change you want to make to the code that makes it.

| I want to change… | Look at | Spec |
|---|---|---|
| Which drink is made next | `gems/deficit_scheduler/lib/` — `pick_next` and its four boosts | §6 |
| The scheduler's tuning knobs | `Store#effective_scheduler_config` → `BuildSchedulerConfig` | §6.6 |
| The wait a customer is quoted | `app/services/project_eta.rb` | §7.1 |
| When ETAs recompute, and how often | `app/services/recompute_eta.rb` — Redis `SET NX PX` debounce | §7.2 |
| What a barista sees / claims | `app/services/claim_next_drink.rb`, `frontend/src/kds/` | §9.4 |
| The pickup board | `app/services/board_view.rb`, `frontend/src/board/` | §9.2 |
| Ordering, cart, checkout | `frontend/src/order/` | §9.3 |
| The simulator and its experiments | `app/simulator/` | §10 |
| The admin dashboard | `frontend/src/dashboard/` | §10.6 |
| Anything about the cluster | `k8s/base/`, overlays in `k8s/overlays/{dev,prod}` | §14 |

| Also | |
|---|---|
| `docs/adr/` | **Why** something is the way it is, when DESIGN.md doesn't say. Immutable — superseded, never edited |
| `docs/testing.md` | Test conventions, coverage gates, the §11 checklist, and what a simulation spec may cost |
| `docs/api/` | OpenAPI, generated by rswag from the request specs — never hand-edited |
| `CLAUDE.md` | Contributor conventions: branches, commits, testing discipline, definition of done |

## Status

The project was built in the order §12 lays out: steps 1–3 produce a shop that functions,
step 4 puts it in a cluster so every later feature ships through Kubernetes, and steps 5–6
are where the design's central claim gets tested against a simulator.

**Steps 0–10 are complete.** The shop takes orders, schedules them with DRR,
runs a kitchen display and a board, deploys to a kind cluster over TLS, projects ETAs forward
through the real scheduler, and handles remakes, offline kiosks and quality timers. The
dashboard has the lane ribbon, metric grid, ablation, quantum sweep, staffing curve and
apply-to-store; rate limiting, Prometheus/Grafana and the `web` HPA are in.

One gap: `NotificationSender.current` always returns `LogSender`, so the §9.7 ready message is
logged, not sent. `TwilioSender` is integration work behind the same port as
`PaymentProvider`, and lands when credentials do.

Postgres runs in-cluster as a StatefulSet (§14.2), which is instructive for a
learning project and wrong for a real store; that would use a managed database.
## Setup

Requires [Docker](https://docs.docker.com/get-started/) and
[mise](https://mise.jdx.dev/) (or any version manager that reads `.ruby-version`
and `.node-version`).

```bash
mise install                 # Ruby 3.4.10, Node 24.19.0
bundle install
npm --prefix frontend install
lefthook install             # commit-msg + pre-commit + pre-push hooks

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

Adding a gem needs `bundle install` **inside** the container, not a rebuild:

```bash
docker compose run --rm --no-deps api bundle install
```

Gems live in a named volume (`bundle:/usr/local/bundle`) that is mounted over the
path the image installed them to, so `docker compose build` alone leaves the
container booting against the old lockfile.

`api` and `worker` run the same image with different commands — the production
topology (§14.1), rehearsed locally so it isn't discovered at deploy time.

## Kubernetes

Every feature after §12 step 4 ships through the cluster rather than being deployed at the
end, which is why CI stands a real cluster up on every push instead of trusting the
manifests to be correct.

```mermaid
flowchart TB
  subgraph ns["namespace: boba-gals"]
    direction TB

    ING["Ingress: boba<br/>/api, /cable → web · else → frontend"]

    subgraph stateless["Deployments"]
      direction LR
      FE["frontend ×2<br/>nginx + React bundle"]
      WEB["web ×2–6<br/>puma + ActionCable"]
      WRK["worker ×1<br/>sidekiq"]
    end

    subgraph stateful["StatefulSets + PVCs"]
      direction LR
      PG["postgres<br/>PVC"]
      RD["redis<br/>PVC · AOF"]
    end

    JOB["Job: migrate<br/>db:prepare, before each rollout"]
    CFG["ConfigMap boba-config<br/>Secret boba-secrets"]

    ING --> FE
    ING --> WEB
    WEB --> PG
    WEB --> RD
    WRK --> PG
    WRK --> RD
    JOB --> PG
    CFG -.-> WEB
    CFG -.-> WRK
    CFG -.-> JOB
  end

  HPA["HPA: 2–6 on CPU"] -.-> WEB
  PDB["PDB: minAvailable 1"] -.-> WEB
  CM["cert-manager<br/>Issuer → boba-tls"] -.-> ING
```

Three details that are easy to get wrong and are load-bearing here:

- **`web` never migrates on boot.** The `migrate` Job owns that, and `web` blocks on an
  init container until the schema it expects is present (§14.2, ADR-0037).
- **Two `web` pods from the first deploy**, so in-process state fails fast rather than
  in production. The HPA's floor keeps that true while scaling (§14.2, ADR-0027).
- **`web` and `worker` are the same image**, differing only in command — the production
  topology, rehearsed by `docker compose` locally.

```bash
bin/k8s-up                   # kind cluster + ingress-nginx + cert-manager + build, load, deploy
bin/k8s-down --app           # delete the app, keep the cluster (fast redeploy)
bin/k8s-down                 # delete the cluster entirely
bin/k8s-down --images        # ...and remove the locally built boba-*:dev images
```

The shop comes up at **https://boba.localtest.me:8443** — board at `/board`.
`localtest.me` resolves to 127.0.0.1, so that is a real hostname with a real
certificate and no `/etc/hosts` entry. Plain http is not served at all (§14.5).

The certificate is signed by a CA the cluster mints itself, so browsers warn.
**Trusting it is optional** — clicking through the warning leaves you on an
`https` origin, so the admin cookie and the websocket both work either way.
`bin/k8s-up` writes the CA to `tmp/boba-ca.crt` and prints the command for your
platform, plus the `curl --cacert` form for scripts, which needs no `sudo`.

None of this applies to `docker compose` above, which is the shorter path to a
running shop and stays on plain http at `localhost:5173`.

`bin/k8s-up` is idempotent: re-run it to redeploy after a code change. Both
teardown modes destroy the dev database; the migrate Job re-seeds on the next
bring-up (ADR-0007).

Requires [kind](https://kind.sigs.k8s.io/) and `kubectl`, and a Docker VM with
room for the whole stack — two `web` pods, two `frontend` pods, a worker,
Postgres, Redis and ingress-nginx:

```bash
colima stop && colima start --cpu 6 --memory 8
```

Colima's 2 GiB default is not enough, and it fails twice over: pods first sit
`Pending` with `Insufficient memory`, and once requests are small enough to
schedule they get `OOMKilled` instead, because the limits then oversubscribe
physical memory. Delete the cluster before resizing the VM
(`bin/k8s-down`), or it comes back half-broken.

CI stands the same cluster up on every push and drives it — order placed
through the ingress, probes checked, Redis pulled out from under the pods — so a
broken manifest fails there rather than on your machine.

## Tests

```bash
bin/rspec                    # full suite; coverage gates enforced
bin/rspec spec/requests      # partial run; gates skipped
COVERAGE=0 bin/rspec         # no instrumentation, for spiking
bundle exec rubocop

npm --prefix frontend run test:run
npm --prefix frontend run lint
npm --prefix frontend run typecheck
```

The scheduler gem carries its own suite and its own gate:
`cd gems/deficit_scheduler && bundle exec rspec`. Gates, conventions and the §11 checklist
are in [`docs/testing.md`](docs/testing.md).

Check the frontend with `run typecheck` (`tsc -b`), never a bare `npx tsc --noEmit` — build
mode walks the project references and so typechecks the test project; the bare form silently
does not.


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

## Layout

| Path | |
|---|---|
| `gems/deficit_scheduler/` | The DRR scheduler (§6), as a domain-neutral path gem with zero runtime dependencies (ADR-0033). Its own specs and golden fixtures live with it. |
| `frontend/` | One React build serving kiosk, web, KDS, board, and dashboard (§9.3). |
| `k8s/base/` | Hand-written manifests (§14.2), folded into Kustomize. |
| `k8s/overlays/` | `dev` for kind, `prod` for the deploy CI targets. |
| `docs/adr/` | Decisions made during implementation. |
| `docs/testing.md` | Test conventions and the §11 scheduler checklist. |
| `CLAUDE.md` | Working agreements — branches, commits, definition of done. |

## Build order

Follow §12. Steps 1–3 give a shop that functions, step 4 puts it in a cluster so
every later feature ships through Kubernetes, and steps 5–6 are where the design's
central claim actually gets tested.

**Current position: steps 0–10 complete.** The shop takes orders, schedules them with DRR,
runs a kitchen display and a board, deploys to a kind cluster over TLS, projects ETAs forward
through the real scheduler, and handles remakes, offline kiosks and quality timers. The
dashboard has the lane ribbon, metric grid, ablation, quantum sweep, staffing curve and
apply-to-store; rate limiting, Prometheus/Grafana and the `web` HPA are in.

One gap: `NotificationSender.current` always returns `LogSender`, so the §9.7 ready message is
logged, not sent. `TwilioSender` is integration work behind the same port as
`PaymentProvider`, and lands when credentials do.

Postgres runs in-cluster as a StatefulSet (§14.2), which is instructive for a
learning project and wrong for a real store; that would use a managed database.

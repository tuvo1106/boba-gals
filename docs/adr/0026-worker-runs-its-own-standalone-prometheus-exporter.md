# ADR-0026: `worker` runs its own standalone Prometheus exporter, on its own port and Service

- **Status:** Accepted
- **Date:** 2026-08-13
- **Design reference:** DESIGN.md §15, §14.2, §14.5
- **Relates to:** ADR-0025

## Context

§15 names `yabeda-sidekiq` alongside `yabeda-rails` for the framework-default metrics.
ADR-0025 deferred adding it: the gem's job/queue metrics live in whichever process runs
Sidekiq, and `worker` mounts no Rack app at all — `bundle exec sidekiq` is a bare
background process, with no Puma, no `config/routes.rb`, nothing for a `/metrics` route
to ride along with the way `web` gets it for free. Adding the gem without solving that
would repeat exactly the trap ADR-0025 worked around for the business gauges: metrics
recorded in a process nobody scrapes, permanently zero, with nothing to say why.

## Decision

Give `worker` its own exporter, its own port, and its own scrape target — a smaller
version of the same shape `web` already has, not a shared one.

**`Yabeda::Prometheus::Exporter.start_metrics_server!`**, called from
`config/initializers/yabeda_sidekiq.rb`, spins up a standalone WEBrick server on a
background thread inside the worker process, listening on port 9394 (the gem's default).
It is gated on `Sidekiq.server?` — true only inside the actual `bundle exec sidekiq`
process, never when the same initializer loads as part of `web` booting the identical
Rails app. Without that gate, `web` would start a second, pointless HTTP server on every
pod.

**A new `worker` Service and `ServiceMonitor`** (`k8s/base/worker.yaml`,
`k8s/monitoring/worker-service-monitor.yaml`), mirroring `web`'s: a `metrics` named port,
a label Prometheus Operator's selector can match, `path: /metrics`, `interval: 30s`. Before
this, `worker` had no Service at all — nothing pointed at it, because it served no traffic
for anything to route to. This is the first thing that does.

`rackup` and `webrick` come along as direct dependencies: `start_metrics_server!` requires
`Rackup::Handler::WEBrick` when the app's Rack version is 3.x (it is — `rack 3.2.6`), and
`webrick` itself was not otherwise in the dependency graph. `rackup` was already present
as a transitive dependency of something Puma-adjacent; `webrick` was not and needed adding
explicitly, or the exporter thread would raise `LoadError` the first time it started.

## Alternatives considered

| Option | Why not |
|---|---|
| Route `worker`'s metrics through `web`'s existing exporter | Prometheus client registries are in-process. `yabeda-sidekiq`'s job/queue counters are recorded by Sidekiq's own middleware, running inside the `worker` process — there is no registry on `web` for them to land in without an out-of-process transport (Redis, a shared file) that doesn't exist and that this option would have to invent. |
| A push gateway: `worker` pushes metrics to Prometheus instead of being scraped | Adds a whole extra component (`pushgateway`) for one process that doesn't otherwise need one. Prometheus's own docs treat push as the exception for jobs that don't outlive a scrape interval; `worker` is a long-running Deployment exactly like `web`, so the pull model already fits it — it was only missing a listener. |
| `sidekiq_alive`-style HTTP server bolted onto a general-purpose gem rather than `yabeda-prometheus`'s own `start_metrics_server!` | `yabeda-prometheus` already ships the standalone-server helper this needs, built to serve exactly the registry the rest of the app's Yabeda config already populates. Reaching for a second gem to do the same job means keeping two exporter mechanisms in sync instead of one. |
| No gate — always call `start_metrics_server!` regardless of process | Starts a second, unused WEBrick server inside every `web` pod. Harmless in isolation but wrong: it claims a port for no reason, and a future reader finding two exporters in one pod has no way to tell which one is load-bearing without reading this ADR. `Sidekiq.server?` is the exact predicate the gem itself uses to gate its own cluster-metric definitions (`yabeda-sidekiq`'s `config.declare_process_metrics`), so gating the server start the same way keeps one mental model instead of two. |

## Consequences

`worker` now listens on two ports: the process still opens no port for application
traffic (§14.3 — there is still nothing for a readiness probe to gate), but 9394 is real
and scraped. A future reader checking "does this pod serve anything" has to know 9394 is
metrics-only, not app traffic — the Service and ServiceMonitor names (`worker`, not
`worker-app` or similar) say so by being the only thing pointing at that pod at all.

`ADR-0025`'s gauges (`quality_breaches`, `remakes`, `queue_depth`,
`concurrent_large_order_rate`) stay exactly as they are — computed fresh from Postgres in
`web`'s `Yabeda.collect` block — even though `worker` can now serve metrics of its own.
That ADR's own "Revisit when" section anticipated this and concluded a fresh read is still
simpler than a `Counter`; nothing about that changes here, because those four gauges were
never about `worker` lacking an exporter — they were about needing a single number across
two `web` pods, which an exporter in `worker` does not affect.

Every Rails process loads every initializer, `config/initializers/yabeda.rb` included, so
`worker`'s exporter now also answers with the `boba_gals_*` gauges, not just
`sidekiq_*` — confirmed by curling it directly (`sidekiq_active_processes` and
`boba_gals_queue_depth` both present in the same response). This is not new
double-counting: a `web` Service backed by 2 pods was already 2 independent scrape
targets before this PR, each answering with its own fresh read of the same query, so any
dashboard panel that sums a `boba_gals_*` gauge across targets rather than reading one was
already summing duplicates. `worker` becoming a third target makes an existing property
more visible, not a new one — `k8s/monitoring/grafana-dashboard.yaml`'s one gauge panel
plots raw series with no `sum()`, so it is unaffected either way. Worth a real fix (label
selection, or `max()` instead of raw/`sum()`) the first time a panel actually needs to
aggregate one of these gauges across targets — not invented here for a panel that doesn't.

## Revisit when

If `worker` ever gains a second workload that needs its own metrics namespace (unlikely —
§16 has no second background process planned), or if the standalone WEBrick thread shows
up as a real cost under load (it has not; `worker` runs one Sidekiq process handling a
handful of light jobs, §14.1).

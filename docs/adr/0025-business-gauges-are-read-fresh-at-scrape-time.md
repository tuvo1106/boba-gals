# ADR-0025: Business gauges are read fresh from Postgres at scrape time, not incremented in-process

- **Status:** Accepted
- **Date:** 2026-08-13
- **Design reference:** DESIGN.md §15, §10.3, §10.4, §14.2
- **Relates to:** ADR-0024

## Context

§15 asks for five business metrics beyond yabeda-rails' framework defaults: queue depth,
a wait-time histogram by size class, ETA signed error, a quality-breach counter, and a
remake counter.

Two of those — quality breaches and remakes — are logged as events (`scheduler_events`
rows: `quality_breach` from `SweepQualityBreachesJob`, `item_remade` from `FailDrink`).
The naive translation to Prometheus is a `Yabeda::Counter`, `.increment`ed at the point
each event is logged. That naive version is broken for this app specifically:
`SweepQualityBreachesJob` runs on `worker` via sidekiq-cron, and Prometheus metrics
libraries hold state in-process. Only `web` mounts `/metrics` (§14.2's two pods); `worker`
has no exporter at all yet, and adding one is genuinely separate work — it needs its own
port, its own scrape target, and the same problem yabeda-sidekiq's framework metrics will
have regardless (deferred to the infra-metrics follow-up). An in-process counter
incremented on `worker` would sit in a registry nobody ever scrapes and silently never
reach Prometheus — not wrong, just permanently zero, which is worse than wrong because
nothing would say so.

Queue depth and concurrent-large-order-rate have a related but distinct problem: even
metrics that *could* be recorded from `web` requests would be split across whichever of
the two `web` pods most recently handled one, with no way to reconcile "the" queue depth
without querying both and picking a winner.

## Decision

**Two different mechanisms, matched to what each metric actually needs:**

The two histograms — `order_wait_seconds`, `eta_signed_error_seconds` — stay genuinely
event-driven, `.measure`d inline from `FinishDrink`, the one call site where an order
actually reaches `ready` (§5.1's forward lifecycle reaches it nowhere else — see the
comment there for why that's exactly-once per transition, KDS undo included). That code
only ever runs inside a `web` request, so the observation lands in a process that gets
scraped. Prometheus histograms need the real observation stream to compute percentiles
correctly; there's no way to reconstruct one from a periodic query after the fact.

The other four metrics — `queue_depth`, `concurrent_large_order_rate`, `quality_breaches`,
`remakes` — are all `Yabeda::Gauge`s, `.set` inside a single `Yabeda.collect` block (`config/initializers/yabeda.rb`) that runs
synchronously on every scrape (`Yabeda::Prometheus::Exporter#call` invokes
`Yabeda.collect!` when the request path matches — confirmed by reading the gem, not
assumed). Each value is queried fresh from Postgres at that moment: `queue_depth` counts
`order_items` directly, `concurrent_large_order_rate` reads `Order.live`, and
`quality_breaches`/`remakes` count their `scheduler_events` rows. Whichever `web` pod
answers a given scrape runs the same query against the same database every other pod
would, so there is nothing process-local left to diverge — the two-pod problem and the
worker problem both disappear the same way, because the source of truth was never the
in-process registry to begin with.

`quality_breaches` and `remakes` end up as gauges rather than the `Counter` type Prometheus
convention would suggest for a monotonic total. That's a deliberate trade: a `Gauge` can be
`.set` to an arbitrary value (including one read from a database), while
`prometheus-client`'s `Counter` only supports `.increment` — there is no `.set`. `rate()`
and `increase()` in PromQL work identically on a monotonically increasing gauge, so nothing
downstream loses functionality; the metric names avoid a trailing `_total`, since that
suffix is a Prometheus convention reserved for the `Counter` type and using it here would
misdescribe what's being served.

## Alternatives considered

| Option | Why not |
|---|---|
| `Yabeda::Counter#increment` at the event source, accepting `worker`'s metrics are unexported until it gets an exporter | Silently wrong now for a "later" that isn't scheduled. Punishes the metric that's actually implemented (quality breaches, the reason this metrics work started) with the same gap that was just spent a whole PR closing. |
| Start a standalone `Yabeda::Prometheus::Exporter.start_metrics_server!` in `worker` now | Real work belongs with the rest of that shape: a new port, a k8s Service/ServiceMonitor for `worker`, and yabeda-sidekiq's own metrics need exactly the same thing. Bundling it here means touching cluster manifests twice for the same reason instead of once, in the PR that's already doing that work. |
| A Redis counter incremented from anywhere, read by the `web` collector | Works, but invents a second source of truth for numbers `scheduler_events` and `order_items` already hold durably. More moving parts for the same answer, and one more thing that could drift from the audit trail. |

## Consequences

Every gauge this file defines costs a handful of queries on every Prometheus scrape
(default 30s interval, §15's `ServiceMonitor`) rather than being free reads of in-memory
counters. At this shop's scale that's the same "measured, this costs nothing" territory
`RecomputeAllEtasJob`'s 30s tick and the quality-breach sweep already sit in — worth
re-measuring if scrape interval ever tightens materially below 30s or the dataset grows
enough that `scheduler_events` counts stop being instant.

If `worker` ever gets its own exporter (the trigger `yabeda-sidekiq` will supply), the
right move for `quality_breaches` and `remakes` specifically is to leave them exactly as
they are — reading `scheduler_events` is still simpler and still correct — rather than
converting them to true `Counter`s just because the option exists.

## Revisit when

`worker` gets a metrics server (tracked implicitly by the infra-metrics follow-up this PR
deferred yabeda-sidekiq to). At that point, decide per-metric whether a fresh read is still
the simpler answer — for the two `scheduler_events`-backed gauges here, it almost certainly
still is.

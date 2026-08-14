# ADR-0029: Sidekiq's scheduled-set poll interval is pinned to ~1 second

- **Status:** Accepted
- **Date:** 2026-08-14
- **Design reference:** DESIGN.md §9.2, §7.2
- **Relates to:** ADR-0016, issue #40

## Context

§9.2 says "throttle board broadcasts to 1/sec." `BoardBroadcast`/`OrderBroadcast` implement
that as a leading-edge-with-trailing-flush window (`ThrottledBroadcast`, ADR-0016):
`WINDOW = 1.second`, and the trailing flush is scheduled with
`flush_job.set(wait: window).perform_later(store.id)`.

`set(wait:)` puts the job in Sidekiq's own scheduled set, which a background poller sweeps
on an interval — not continuously. That poller's default interval scales with process
count and targets roughly one check every `process_count * 5` seconds, with up to 1.5x that
in jitter to avoid every process waking at once. `worker` runs a single replica (§14.2), so
the default resolves to an average ~5s poll with up to 7.5s of jitter on top of it.

Measured on the compose stack (issue #40), two drinks finishing in the same second:

```
enqueued  02:26:57.549  BoardFlushJob
performed 02:27:04.800  BoardFlushJob   (+7.25s)
```

The leading edge is unaffected and instant — this only bites the second and later
transitions inside a window. Observed as: the database already says `ready`, but the
customer's screen and the board sit on the previous frame for several seconds. That is a
worse trailing edge than §9.2's "1/sec" implies, and worse than `WINDOW`'s own value
suggests to a reader who doesn't know Sidekiq schedules jobs by polling rather than by timer.

## Decision

Pin Sidekiq's scheduled-set poll interval directly: `config[:poll_interval_average] = 1` in
`config/initializers/sidekiq.rb`, applied via `Sidekiq.configure_server` so only `worker`
sets it. This overrides the process-count scaling entirely rather than tuning
`average_scheduled_poll_interval` (the per-process input to that scaling) — `worker` is
fixed at one replica by design (§14.2), but a direct override doesn't silently drift out of
sync with this decision's reasoning if that ever changed for an unrelated reason.

With `poll_interval_average` set, Sidekiq's own jitter formula for small clusters
(`interval * rand + interval / 2`) gives a poll delay uniformly distributed across
[0.5s, 1.5s), averaging 1s. Total trailing-edge latency becomes `WINDOW` (1s, deterministic)
plus that jitter: roughly 1.5s on average, up to 2.5s worst case — down from an average
poll delay of ~5-7.5s beforehand.

This is a global setting: it also speeds up polling for Sidekiq's own retry set and the
other two `set(wait:)` schedules in the app (`RecomputeEtaJob`'s ETA debounce, §7.2; the
60s KDS undo window, §9.1). All three benefit from tighter timing for the same reason the
broadcast flush does, and none of them are harmed by it — the undo window in particular
already tolerates its own several-second slop today, so making it more precise has no
downside. `worker` runs one replica with no significant retry volume (no external API calls
besides Twilio SMS, §9.7, and `PaymentProvider.authorize` always succeeds today, §9.3), so
the wider poll on the shared retry set costs nothing distinguishable in exchange.

Comments on `BoardFlushJob`, `OrderFlushJob`, and `BoardBroadcast`/`OrderBroadcast`'s "1/sec"
language now note that this describes the window, not a delivery guarantee — Sidekiq's own
scheduled-set poller sits between the two, and always will, regardless of how tightly it's
tuned.

## Alternatives considered

| Option | Why not |
|---|---|
| Give the flush its own dedicated poller, outside Sidekiq's scheduled set | Would mean reimplementing what `Sidekiq::Scheduled::Poller` already does — a Redis sorted set plus a tight-interval sweep — as bespoke code, just to get a tighter interval than the shared one. More surface to maintain and cover for a result this config change gets in one line. `BoardFlushJob`/`OrderFlushJob`'s own reasoning for using Sidekiq at all (survives the pod that scheduled it) applies equally to a hand-rolled poller only if that poller is itself run by Sidekiq — at which point it's just this option with extra steps. |
| Accept the latency and only fix the comments | Leaves a real, customer-visible defect in place (a drink already `ready` in the database, still showing "in progress" for several seconds) to avoid a one-line config change with no discovered downside. |
| Tune the interval tighter than 1s (e.g. 0.5s) | §9.2 asks for "1/sec," and 1s already cuts the measured worst case from 7.25s to roughly 2.5s. Going tighter buys diminishing returns against a target that's already itself approximate, for more Redis polling with no stated requirement driving it. |

## Consequences

The board and a customer's order screen now update within roughly 1.5-2.5s of a drink
transition landing inside an active throttle window, down from as much as 7.25s measured.
The leading-edge case (already instant) is unaffected.

Sidekiq's retry set and the ETA debounce (§7.2) are polled on the same tightened schedule as
a side effect. Both improve for the same reason without meaningfully worse resource cost at
this app's scale.

If `worker` ever moves to more than one replica, the direct `poll_interval_average` override
means the poll interval stays at ~1s rather than scaling down further with process count the
way Sidekiq's own default would — a deliberate tradeoff for staying legible about what's
actually configured, revisited below.

## Revisit when

`worker` moves to more than one replica (§14.2 currently fixes it at one) — multiple
processes polling this same tight interval multiplies Redis load for no benefit, since only
one process needs to notice a given due job. At that point, switch back to
`average_scheduled_poll_interval` (the per-process input) so the effective average interval
scales down automatically, or drop the override if replica count makes the default already
tight enough.

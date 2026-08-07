# ADR-0008: Readiness checks Postgres and Redis; liveness only checks the process

- **Status:** Accepted
- **Date:** 2026-08-07
- **Design reference:** DESIGN.md §14.3 (probes), §14.4 (multi-pod correctness), §9.1 (health)

## Context

§14.3 specifies Rails' built-in `/up` for **both** `web` liveness and readiness, with the
rationale that "readiness gate on DB connectivity is automatic (`/up` raises if the app
can't boot its connections)."

That premise is false. Rails' own documentation for the health controller says:

> This endpoint does not reflect the status of all of your application's dependencies, such
> as the database or Redis cluster.

It returns 200 if the application booted, and boot does not open a database connection.

Observed on the first `kind` deploy: `web` pods reported `1/1 Running` — Ready, and
therefore receiving traffic through the Service — while `postgres-0` was still `Pending`
and the database did not exist at all.

This matters more here than it would in a typical app, because §14.4 makes Redis
load-bearing rather than a cache. A pod that cannot reach Redis cannot broadcast across
pods (ActionCable's adapter), cannot take the board's throttle lock (§9.2), and from build
step 5 cannot read the scheduler's deficits (§6.5). It is not degraded; it is wrong.

## Decision

**Split the two probes**, because they answer different questions:

| Probe | Path | Asks | On failure |
|---|---|---|---|
| Liveness | `/up` | Is the process wedged? | Kubernetes restarts the pod |
| Readiness | `/readyz` | Can this pod serve a request? | Kubernetes removes it from the Service |

`/readyz` is a new `ReadinessController` that runs `SELECT 1` against Postgres and `PING`
against Redis, returning 503 with a per-dependency breakdown when either fails.

**Liveness stays off the database, deliberately.** Gating it on Postgres would mean a
database blip restarts every `web` pod simultaneously — turning a recoverable dependency
failure into a full outage, and adding cold-start latency at exactly the wrong moment.
Restart is the right response to a wedged process and the wrong response to a sick
dependency.

`SELECT 1` rather than `ActiveRecord::Base.connection.connected?`: the latter reports on
the connection object, not the server, and stays true across a Postgres restart until
something actually tries to use it.

`/api/v1/health` (§9.1) remains untouched by either probe. It is business-level and
includes `stores.accepting_orders`; §14.3 is explicit that an owner switching ordering off
must not cause Kubernetes to restart pods, and that separation is the whole reason there
are three endpoints rather than one.

Rejected alternatives:

- **Leave `/up` on both, as written.** Rejected on evidence: it demonstrably admits pods
  with no database into the Service.
- **Point readiness at `/api/v1/health`.** Would work mechanically and would collapse
  exactly the separation §14.3 spends a paragraph protecting.
- **An `initContainer` on `web` that waits for Postgres.** Fixes cold start only. Readiness
  has to keep being true, not merely have been true once — a database that goes away an
  hour after rollout is the case that matters.

## Consequences

**This contradicts §14.3.** Per CLAUDE.md that also means editing `DESIGN.md`: the `web`
row should name `/readyz` for readiness and drop the claim about `/up` raising, in its own
PR that changes nothing else.

**Readiness now costs two round trips per probe, every 5 seconds, per pod.** At two
replicas that is trivial, and both checks are the cheapest possible form. The 503 response
names which dependency failed, so a not-ready pod does not require reading logs to
diagnose.

**A total Redis outage takes the whole `web` Deployment out of the Service** rather than
leaving it serving degraded. That is the intended reading of §14.4 — without Redis the
board and KDS silently stop updating, which is worse than a visible failure — but it is a
deliberate availability trade and worth knowing before a Redis upgrade.

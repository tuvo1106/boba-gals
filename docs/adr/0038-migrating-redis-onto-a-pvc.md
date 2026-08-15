# ADR-0038: Migrating Redis onto a PVC

- **Status:** Accepted
- **Date:** 2026-08-15
- **Design reference:** DESIGN.md §14.2, §14.4, §6.5, §17
- **Relates to:** ADR-0037

## Context

DESIGN.md §14.2 now calls for a persistent Redis, because Sidekiq shares the instance and a
job is not reconstructible from Postgres. That decision and its reasoning live in the
specification. What it does not cover is how an already-running cluster gets there, and that
turns out to be the sharp part.

**A StatefulSet's `volumeClaimTemplates` is immutable.** Going from `volumes: [{emptyDir: {}}]`
to a `volumeClaimTemplates` entry is exactly the kind of change the API rejects. Verified on a
throwaway kind cluster rather than assumed — the old definition applied first, then the new
one over it:

```
The StatefulSet "redis" is invalid: spec: Forbidden: updates to statefulset spec for
fields other than 'replicas', 'ordinals', 'template', 'updateStrategy',
'revisionHistoryLimit', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds'
are forbidden
```

This is the second immutability trap in two PRs — ADR-0037 fixed the same shape on the
`migrate` Job — and it fails the same way: invisibly to every test, loudly at deploy time, and
only on a cluster that already exists.

**CI cannot catch it.** `helm/kind-action` builds a fresh cluster on every run
(`.github/workflows/ci.yml:200`), so the cluster job only ever exercises a first install.
The upgrade path executes exactly where CI is not: a laptop's long-lived kind cluster, and
any real deployment.

## Decision

`bin/k8s-up` deletes the `redis` StatefulSet before applying, **but only when it has no
`volumeClaimTemplates`**:

```sh
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 &&
   kubectl -n "$NAMESPACE" get statefulset redis >/dev/null 2>&1 &&
   [ -z "$(kubectl -n "$NAMESPACE" get statefulset redis \
             -o jsonpath='{.spec.volumeClaimTemplates}' 2>/dev/null)" ]; then
  kubectl -n "$NAMESPACE" delete statefulset redis
fi
```

The narrowness is the point. An unconditional delete would work once and then tear Redis down
on every subsequent deploy — an outage each time, for a store that is load-bearing (§14.4).
Gating on the old shape makes this a one-time migration that disarms itself.

Deleting a StatefulSet does not delete its PVCs; `persistentVolumeClaimRetentionPolicy`
defaults to `Retain`. So this is safe to re-run even if the condition were somehow met again,
and the volume being replaced held nothing durable by definition — it was an `emptyDir`.

## Alternatives rejected

**`kubectl replace --force`.** Deletes and recreates unconditionally, which is the outage-per-
deploy problem above with no guard to stop it.

**Rename the StatefulSet** (`redis` → `redis-v2`) so the old one is simply orphaned. Avoids the
delete entirely, but leaves a dead StatefulSet in every existing cluster for someone to find
later, and drags the Service selector and `REDIS_URL` along with it. The rename would outlive
its reason by years.

**Leave `emptyDir` and give Sidekiq its own durable Redis.** Considered and rejected in the
DESIGN.md PR, on ops weight — a second StatefulSet, URL, probe and dashboard for a shop doing
hundreds of orders a day.

**Do nothing and document the manual step.** A migration that depends on someone reading a
release note is a migration that does not happen.

## Consequences

The first `bin/k8s-up` against an existing cluster restarts Redis once. Everything in there is
either reconstructible (§6.5) or already at risk from any restart, so the cost is one round of
scheduler unfairness — the same cost §6.5 already accepts.

A PVC that cannot bind leaves Redis unschedulable, and Redis is load-bearing, so a cluster
with no default StorageClass now fails to come up rather than running degraded. kind provides
`standard`; a real cluster needs one configured.

Verified end to end on a throwaway kind cluster, then deleted:

- the guard fires against the old `emptyDir` StatefulSet, and the apply that had just been
  rejected then succeeds;
- the guard stays silent once `volumeClaimTemplates` is present, and a repeat apply reports
  `statefulset.apps/redis configured` rather than recreating anything;
- the PVC binds against kind's `standard` class, and `appendonly`/`appendfsync`/
  `maxmemory-policy` read back as `yes`/`everysec`/`noeviction` inside the pod;
- a job pushed onto `queue:default` survives `kubectl delete pod redis-0`.

Separately, against `redis:7` directly: the same job survives `kill -9` under the new
settings and is **lost** under the old `--appendonly no` — which is the whole claim, tested
from both sides.

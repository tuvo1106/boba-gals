# ADR-0027: `web` autoscales on CPU with a two-pod floor; `metrics-server` joins the kind cluster to make that real

- **Status:** Accepted
- **Date:** 2026-08-13
- **Design reference:** DESIGN.md §14.2, §14.4, §14.5
- **Relates to:** ADR-0026

## Context

§14.5 names the last piece of step 10: "HPA on `web` (CPU-based is fine; the app is
stateless per-request) → PodDisruptionBudget on `web`." The what is decided; the how is
not — DESIGN.md gives no replica bounds, no CPU target, and no PDB shape, and kind carries
no metrics pipeline for a CPU-based HPA to read from at all. `kubectl top pod` and any
`autoscaling/v2` `Resource` metric both depend on `metrics-server`, which is not part of a
stock Kubernetes install and is not one of this project's own manifests — it is
infrastructure the cluster itself needs, the same category `ingress-nginx` and
`cert-manager` are already in.

## Decision

**`metrics-server` installs the same way `ingress-nginx` and `cert-manager` already do**
(`bin/k8s-up`): third-party, pinned version, applied from its released manifest, guarded by
an existence check so a re-run doesn't reapply it. One kind-specific patch is required on
top of the stock manifest: `--kubelet-insecure-tls`, added via `kubectl patch` immediately
after apply. Kind's kubelets present certificates metrics-server doesn't trust by default,
and without the flag every pod's CPU/memory reads `<unknown>` in `kubectl top` and in the
HPA's own `TARGETS` column forever, with nothing else in the system saying why. This is not
gated behind `$CI` the way `kube-prometheus-stack` is (§15) — that gate exists because
Prometheus/Grafana are pure observability weight the cluster smoke test doesn't need to
prove the app works; `metrics-server` is a load-bearing dependency of the HPA this PR adds,
so CI needs it too, to prove the HPA is reading real numbers and not silently inert.

**`minReplicas: 2`, `maxReplicas: 6`, target 70% CPU utilization.** The floor is not a
scaling choice — it restates §14.2's non-negotiable: two `web` pods from the start, because
a single pod hides in-process assumptions three places in the design would otherwise get
away with (the ETA debounce lock, the board broadcast throttle, ActionCable's Redis
adapter). The ceiling is sized off Postgres, not off any traffic estimate this project has
grounds to make: each `web` pod opens up to `RAILS_MAX_THREADS` (5) connections, so 6 pods
tops out at 30 against `postgres:16`'s default `max_connections: 100`, leaving headroom for
`worker` and a human `psql` session. 70% utilization on a 200m CPU request leaves a
pod room to absorb a burst before the HPA reacts, without sitting so far under the request
that autoscaling barely ever triggers.

**The Deployment's `replicas` field is removed, not set to match `minReplicas`.** Once an
HPA targets a Deployment, it writes `spec.replicas` directly. `kubectl apply` uses a
strategic merge and only touches fields present in the local manifest — a manifest that
still said `replicas: 2` would win that fight on every deploy, silently resetting whatever
the HPA had scaled to back down to 2 the next time CI ships a new image tag. Omitting the
field means `kubectl apply -k` leaves the live value, whatever the HPA currently has it at,
alone.

**`PodDisruptionBudget` uses `minAvailable: 1`, not `maxUnavailable: 1`.** At today's floor
of 2 replicas the two are numerically identical, but they diverge the moment the HPA scales
up: `minAvailable: 1` keeps meaning "at least one pod always serving" at any replica count,
while a fixed `maxUnavailable: 1` would let a growing fraction of the fleet go down at once
as replica count rises — the wrong direction for a budget meant to protect availability.

## Alternatives considered

| Option | Why not |
|---|---|
| Skip `metrics-server`, verify the HPA manifest applies but not that it reads real metrics | Proves the YAML parses, not that autoscaling works. This project's own established pattern (ADR-0025, ADR-0026, and the `/metrics serves real data` CI checks) is to prove a real number moved through the real path, not just that a 200 or a clean `apply` came back. |
| Gate `metrics-server` behind `$CI` the way `kube-prometheus-stack` is | Different category of thing: Grafana/Prometheus are observability the smoke test doesn't need; `metrics-server` is what the HPA this PR ships depends on to do anything. Skipping it in CI would mean CI never actually exercises the feature being added. |
| Leave `replicas: 2` on the Deployment alongside the HPA | Fights the HPA on every apply — the live cluster's actual replica count would revert to 2 on the next deploy regardless of load, defeating the point of adding autoscaling at all. |
| `maxUnavailable: 1` on the PDB | Identical to `minAvailable: 1` only at exactly 2 replicas. Diverges as soon as the HPA scales past the floor, and in the wrong direction for what a disruption budget is supposed to guarantee. |
| Size `maxReplicas` off a guessed traffic ceiling | Nothing in this project's own scale claims (§10's simulator work) is about `web`'s HTTP throughput — the design's whole thesis is that scheduling fairness, not raw request handling, is the constraint that matters. Postgres' connection ceiling is a real, checkable number; a traffic guess isn't. |

## Consequences

`web` now depends on `metrics-server` being healthy to autoscale at all — if it's down, the
HPA holds at its last known replica count rather than reacting, which degrades to "runs at
whatever it was" rather than failing requests, the same fail-safe direction the readiness
probe split (ADR-0008) already favors elsewhere in this deployment.

`kubectl apply -k k8s/overlays/dev` (or `prod`) no longer fully declares `web`'s replica
count — reading the live count now requires `kubectl get deployment/web` or
`kubectl get hpa/web`, not just the manifest. Anyone changing the two-pod floor has to edit
the HPA's `minReplicas`, not the Deployment; `git grep replicas: k8s/` finding nothing under
`web.yaml` is expected, not a bug.

## Revisit when

`maxReplicas: 6` or the CPU target if a real deploy's traffic shape turns out to look
nothing like this estimate, or if `RAILS_MAX_THREADS`/`max_connections` change — the two
numbers were derived together and should be revisited together, per the comment in
`k8s/base/web.yaml`.

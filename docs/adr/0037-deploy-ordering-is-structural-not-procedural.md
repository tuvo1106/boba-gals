# ADR-0037: Deploy ordering is structural, not procedural

- **Status:** Accepted
- **Date:** 2026-08-15
- **Design reference:** DESIGN.md §14.2, §14.3
- **Relates to:** ADR-0007, ADR-0008

## Context

§14.2 is explicit that migrations belong to a Job applied before each `web` rollout, never to
container boot. The manifests implemented the first half and left the second to a shell
script. A review of `k8s/` found three ways that arrangement was not holding.

**The migrate Job was never name-hashed.** `k8s/base/migrate-job.yaml` carried a comment
asserting that "Kustomize appends a content hash to the name, so each apply creates a *new*
Job rather than failing on an immutable existing one". Kustomize does that only for
`configMapGenerator` and `secretGenerator` output — never for a resource listed under
`resources:`. `kubectl kustomize k8s/overlays/prod` emits the Job as plain `migrate`.

A Job's pod template is immutable, so an un-hashed Job that outlives its run breaks both
overlays, in opposite directions:

- **dev.** `ttlSecondsAfterFinished: 600` keeps the completed Job for ten minutes, and the
  dev image tag is always `dev`, so re-applying inside that window submits a byte-identical
  spec. `kubectl apply` is a no-op, the *old completed* Job survives, and
  `kubectl wait --for=condition=complete job/migrate` returns instantly against a Job that
  ran before the new migration existed. `bin/k8s-up` then rolls `web` onto an unmigrated
  schema and reports success. After ten minutes the TTL has reaped the Job and the same
  command works — a bug that depends on how recently you last deployed.
- **prod.** CI rewrites the image to a SHA tag, so the pod template genuinely changes and the
  apply fails with `spec.template: field is immutable`.

**Nothing sequenced the Job against the Deployment.** `kubectl apply -k` creates both at
once. `bin/k8s-up` waits on the Job and then restarts `web`, but that is the *dev* script;
the prod overlay is base plus an image list and has no equivalent. The ordering §14.2
requires existed only where someone had written it out by hand.

**A liveness probe called a binary the image does not contain.** `k8s/base/worker.yaml` ran
`pgrep -f sidekiq`; `pgrep` ships in `procps`, which the Dockerfile has never installed.
Verified against the built image:

```
$ docker run --rm --entrypoint pgrep boba-api:dev -f sidekiq
exec: "pgrep": executable file not found in $PATH     # exit 127
```

Every check failed from the first one. At `periodSeconds: 30` and `failureThreshold: 3` the
kubelet killed the container roughly every two minutes, permanently. It survived since PR #7
because nothing gated on `worker`: `bin/k8s-up` ran `rollout status` on `web` and `frontend`
only, and CI's single worker assertion is a `kubectl exec` that succeeds during any up-window
between restarts.

## Decision

**Ordering moves into the manifests.** `web` gets a `wait-for-migrations` init container that
polls the database, in SQL, until `schema_migrations` contains the version recorded in the
image's own `db/schema.rb`. This *waits* for migrations and never runs them, so §14.2's
prohibition and the `spec/config/invariants_spec.rb` guard on `bin/docker-entrypoint` both
stand. Ordering now holds in any overlay, under a bare `kubectl apply -k`, with no deploy
script involved.

**The check is read-only SQL, not `bin/rails db:abort_if_pending_migrations`.** That was the
first implementation and it broke the cluster on its first CI run, in a way worth recording
because the mechanism is not obvious.

`POSTGRES_DB` makes initdb create `boba_gals_production`, so the database always exists by
the time the Job runs. `db:prepare` therefore cannot use "does the database exist" to decide
whether to seed, and uses "does `schema_migrations` exist" instead. The Rails pending-check
**creates that table as a side effect** on a database that lacks it. So the init container,
polling every two seconds, raced the Job and flipped `db:prepare` onto its already-initialised
path: migrations ran, `load_seed` did not, and the cluster came up with no store, no menu and
no admin user while the Job reported success. Confirmed directly rather than inferred:

```
$ psql -d empty -tAc "SELECT to_regclass('schema_migrations')"    # (nothing)
$ bin/rails db:abort_if_pending_migrations                        # exit 1
$ psql -d empty -tAc "SELECT to_regclass('schema_migrations')"    # schema_migrations
```

A `SELECT` cannot do that. It also boots no Ruby, so each poll costs a connection rather than
a Rails process, and it reads the version from the image, which keeps it correct when an older
image is rolled back onto a newer schema.

**The stale Job is deleted rather than hashed.** `bin/k8s-up` runs
`kubectl delete job/migrate --ignore-not-found` before applying. The false comment is
replaced with what is actually true and why it matters.

**`procps` joins the base image**, restoring the probe the manifest always intended, and
`bin/k8s-up` now waits on `deployment/worker` alongside `web` and `frontend`.

**A unit spec reads the manifests against the Dockerfile.** `spec/config/invariants_spec.rb`
fails if any exec probe on a container running our own image invokes a binary the Dockerfile
does not install. It is scoped to `image: boba-api` — `postgres` and `redis` bring their own
images and `redis-cli` is not this repository's business.

## Alternatives rejected

**`generateName` on the Job.** `kubectl apply` requires a name; `generateName` works only
with `create`. Adopting it means the deploy path stops being declarative, which costs more
than the problem is worth.

**`ttlSecondsAfterFinished: 0`.** Reaps the Job immediately and removes the collision, but
also removes `kubectl logs job/migrate` at exactly the moment a failed rollout is being
investigated — and races the `kubectl wait` that follows it.

**Ordering in the deploy script only.** This is what already existed, and it is what failed:
the guarantee lived in dev's script and prod had no script. A `preSync`-style hook would work
but means adopting a deploy tool the project does not use (§14.1 rules out Kamal for related
reasons).

**A sidekiq_alive-style HTTP probe** instead of installing `procps`. It answers a slightly
better question — a wedged Sidekiq still appears in `pgrep` — but costs a gem and a port, and
the manifest's own comment already weighed and rejected that. Making the existing probe work
is the smaller change; a liveness probe that detects deadlock is a separate decision with its
own evidence, not a thing to smuggle into a fix.

## Consequences

`web` pods now wait for the schema before starting, which on a cold cluster adds however long
the migrate Job takes. The poll itself is a single `SELECT` every two seconds against a
Postgres in the same namespace, so the cost is the waiting, not the checking.

Deploying no longer depends on the ten-minute TTL window having elapsed, and prod can be
deployed twice in a row.

The worker will now genuinely crash-loop if Sidekiq dies, which is the intended behaviour and
was not previously observable — and `bin/k8s-up` will fail rather than report success.

Verified in the production image against a live Postgres, running the command exactly as
`kubectl kustomize` renders it: it prints the expected version and exits 0 against a migrated
database, blocks against an empty one, and leaves that empty database with no
`schema_migrations` table — which is the specific regression above, now proven absent. Running
the Job's `db:prepare` against a database the check had polled seeds normally: 1 store,
9 menu items, 1 admin.

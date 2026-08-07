# ADR-0007: The migrate Job runs `db:prepare`, not `db:migrate`

- **Status:** Accepted
- **Date:** 2026-08-07
- **Design reference:** DESIGN.md §14.2 (manifest layout), §13.4 (admin), §12 step 4

## Context

§14.2 specifies a `migrate` Job running `bin/rails db:migrate`, applied before each `web`
rollout, and is emphatic that migrations must never run on container boot — two `web` pods
would race the same schema change, and a crash-looping pod would retry it forever.
`spec/config/invariants_spec.rb` enforces the boot half of that rule.

The Job's *command* has a gap the design doesn't address: `db:migrate` requires the
database to already exist. On a cluster brought up from nothing — which is every `kind`
cluster, and the first real deploy — there is no database for it to migrate, and the Job
fails.

There is a second bootstrap problem behind it. `Api::V1::BaseController#current_store` is
`Store.first!`, so an empty database means every endpoint 404s. And §13.4 says the admin
user is "created via seed, no signup". The seed *is* the bootstrap; it is not optional
sample data.

## Decision

**The Job runs `bin/rails db:prepare`.**

`db:prepare` creates the database, loads the schema and runs seeds when the database did
not exist, and on every subsequent run migrates and does nothing else. One command that is
correct on the first deploy and on the two-hundredth, which is what makes it safe to have
CI apply unconditionally before each rollout.

`db/seeds.rb` uses `find_or_create_by!` throughout, so re-running it is a no-op rather than
a duplicate-data event. That matters because it means the choice is not load-bearing on
`db:prepare`'s "only when freshly created" behaviour being exactly right.

Rejected alternatives:

- **Keep `db:migrate`, bootstrap separately.** A one-shot `db:prepare` for a new cluster,
  then `db:migrate` for every rollout after. Arguably safer: a rollout against an
  accidentally-empty production database would then fail loudly rather than quietly seeding
  a demo menu. Rejected because it makes the first deploy a special case that is performed
  rarely and therefore always slightly wrong, and because on this project the cluster is
  torn down and recreated constantly — the "rare" path is the common one.
- **`db:migrate` plus an init container that creates the database.** Splits one command
  into two places for no gain.

## Consequences

**This contradicts §14.2.** Per CLAUDE.md, a decision that contradicts the design also
updates `DESIGN.md` — §14.2's `migrate` row should read `bin/rails db:prepare`, and that
edit belongs in its own PR that changes nothing else.

**A rollout against an empty production database will seed it.** With demo menu data, a
demo store, and baristas whose PIN is `1234`. That is the intended bootstrap, but it means
an operator who points the app at the wrong database gets a plausible-looking shop rather
than an error. The mitigation is that `DATABASE_URL` lives in a Secret created out of band
(§14.6), not in anything this repo can get wrong on its own.

**`SEED_ADMIN_PASSWORD` becomes deploy-critical.** `db/seeds.rb` falls back to
`changeme-in-any-real-deploy`, and with `db:prepare` in the rollout path that fallback
would become the live admin password on first deploy. It must be set in the Secret before
the cluster is first brought up. The dev overlay sets it to `dev-admin`, which is fine for
something that lives on a laptop and is deleted with `kind delete cluster`.

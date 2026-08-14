<!-- Write "n/a" rather than deleting a section — a consistently shaped PR log is
     searchable later. Future-you is the reviewer. -->

## Summary

<!-- Two or three sentences: what changed and why now. -->

**Design reference:** DESIGN.md § · **Build step:** <!-- §12 step, or n/a -->

## Why this approach

<!-- The part worth writing down: what you rejected and why. If DESIGN.md already settled
     it, cite the section and move on. If this is a NEW decision, it needs an ADR — link it. -->

## Testing

**Added:**

-

**Coverage:** overall ___% (gate 90%) · `gems/deficit_scheduler` ___% (gate 100/100, its own suite)

**Golden tests:** unchanged / regenerated — <!-- if regenerated: what behavior changed, and why that's correct -->

**Verified by hand:**

<!-- Steps someone could follow. "Ran the app" is not a step. Screenshots for any KDS,
     board, ordering, or dashboard change — with the seed, for the sim dashboard. -->

## Ops

<!-- Delete the lines that don't apply; keep the heading. -->

- **Migrations:** none / `<name>` — reversible? backfill?
- **Env vars:** none / `<NAME>` — Secret or ConfigMap (§14.6)?
- **Manifests:** none / `k8s/...`
- **Dependencies:** none / `<gem>` — why it's worth the weight
- **Jobs:** none / `<job>` — recurring (sidekiq-cron)?

## Risk

**If this is wrong:** <!-- who notices — a customer, a barista, nobody? -->
**Rollback:** <!-- clean revert, or does a migration make it one-way? -->

## Checklist

- [ ] `CHANGELOG.md` updated under `## [Unreleased]`
- [ ] Public classes/methods have YARD comments citing `§` where relevant
- [ ] New decisions recorded as an ADR
- [ ] `bundle exec rubocop` / `npm run lint` clean, coverage gates hold

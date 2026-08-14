# ADR-0030: rswag lands as parallel specs, and the frontend types are a generated shim

- **Status:** Accepted
- **Date:** 2026-08-14
- **Design reference:** DESIGN.md §9.1 (API surface), §11 (testing) — same references as ADR-0002

## Context

ADR-0002 decided rswag would generate `docs/api/openapi.yaml` from the request specs at
build step 4. Step 4 shipped without it — `rswag` never made it into the `Gemfile`,
`docs/api/` never existed, and `frontend/src/api/types.ts` stayed ~380 lines of
hand-written interfaces "kept in step by hand," verified only by whichever test happened
to exercise a field. Issue #70 (found during the #68 comment sweep) named the gap and the
two honest ways to close it: land rswag for real, or write a new ADR admitting the
hand-written types are deliberate. Tu chose to land it, including generating the frontend
types in the same PR rather than deferring that half.

ADR-0002 decided *that* rswag would generate the doc. It did not decide *how* the eleven
existing request-spec files would coexist with rswag's DSL, or how a generated OpenAPI
document turns into the exact named TypeScript exports 31 frontend files already import.
Both needed an answer before landing.

## Decision

**Parallel `*_swagger_spec.rb` files, not a rewrite.** Each existing `spec/requests/api/v1/
*_spec.rb` correctness file gets a sibling `*_swagger_spec.rb` using rswag's `path`/
`response` DSL — same auth helpers and factories, a minimal happy-path-plus-documented-
error-status set rather than the full edge-case matrix the correctness spec already owns.
The correctness specs are untouched. This is slightly more code than rewriting them in
place would be, but it does not put a green, well-exercised suite at risk to add
documentation.

**Component schemas are named and hand-authored in `spec/swagger_helper.rb`**, not
declared inline per path. `components.schemas` entries are what `openapi-typescript` turns
into named exported types (`components['schemas']['MakingRow']`); an inline schema on a
single path produces an anonymous type with nothing to re-export by name. Each schema is a
mechanical translation of the matching `types.ts` interface that existed before this PR —
same field names, `nullable: true` for `| null` unions, `enum` for string-literal unions,
`required` listing every field so `openapi-typescript` doesn't mark everything optional.

**The frontend split is `generated.ts` (fully generated, never hand-edited) +
`types.ts` (thin, hand-written re-exports).** `frontend/src/api/types.ts` becomes
`export type MakingRow = components['schemas']['MakingRow']` for every schema, keeping
every export name and the import path all 31 consuming files already use — the change is
invisible to every one of them. `Policy` is the one type kept fully hand-written: it's a
client-side union broader than any single response (`SchedulerConfig['policy']` is
narrower, since the server refuses `rr`/`sjf`), so no schema is the right source for it.

**Discovered, not decided, but worth recording:** `openapi-typescript@7.13.0`'s
`peerDependencies` caps at `typescript ^5.x`, and this repo is on `~6.0.2`. `npm install`
and `npm ci` both need `--legacy-peer-deps` as a result. That flag also makes npm's
resolver silently drop `@testing-library/dom` — an implicit peer of
`@testing-library/react`, not a direct dependency — rather than warning, which broke every
frontend test suite (`Cannot find package '@testing-library/dom'`) with a passing install
and no error until `vitest run`. Fixed by pinning `@testing-library/dom` directly in
`package.json` so it survives regardless of peer-resolution mode. Caught by running the
*true* clean baseline (`git stash -u && npm ci`) after the first broken attempt looked
clean — the first attempt's "pre-existing" typecheck errors were actually caused by the
same install, just not yet visibly connected to it.

**One schema was nearly loosened incorrectly, which is the point of doing this at all.**
The first `orders_swagger_spec.rb` fixture built a bare `Order` via `create(:order, ...)`
with no items, and schema validation failed on `quoted_wait_seconds` being `null` against a
`number` schema. The honest fix was checked before either side moved: `ProjectEta.for_order`
always `.fetch(order.id, 0)`s a non-nil Integer on the real `CreateOrder` path, so a
placed order's `quoted_wait_seconds` is never actually null — the schema was right and the
test fixture was the gap, not `types.ts`. Fixed the fixture (create a real order with an
item, matching what `POST /orders` actually returns), not the schema. Loosening the schema
to `nullable: true` would have been the easy fix and the wrong one — exactly the kind of
one-character error this whole ADR exists to make loud instead of silent.

## Alternatives considered

| Option | Why not |
|---|---|
| Rewrite the 11 correctness specs into rswag's DSL | Puts a green, well-exercised suite at risk for documentation gain; CLAUDE.md already flags "rewriting a green suite has its own risk." |
| Inline per-path response schemas | `openapi-typescript` only names a type per `components.schemas` entry — inline schemas produce anonymous types, which breaks the re-export shim entirely. |
| Generate directly into `types.ts` | Loses the one legitimately hand-kept type (`Policy`) and means every future generation run has to know to skip one file's worth of exports rather than fully owning a separate file. |
| `rswag-api` / `rswag-ui` (served docs) | Nothing in this repo serves API docs, and a solo learning project has no audience for them — matches ADR-0002's own framing. |
| Loosen `quoted_wait_seconds` to nullable | Would have been correct-looking (it made the failing test pass) but false to the real contract — `ProjectEta.for_order` never returns nil on the path the API actually exercises. The bug was the fixture. |

## Consequences

Adding or changing a documented field now means three things land together in one PR:
the `components.schemas` edit in `spec/swagger_helper.rb`, `docs/api/openapi.yaml`
regenerated (`bundle exec rails rswag:specs:swaggerize`), and
`frontend/src/api/generated.ts` regenerated (`npm run generate:types`) — CI fails on
either generated file drifting from what's committed, so there's no way to land one
without the other two.

A genuinely new field on an *existing* schema will be caught by CI the moment the
response actually differs from the schema (rswag's response validator, not just the drift
check). A **new endpoint added with no `*_swagger_spec.rb` entry is not caught by
anything** — nothing currently forces a new route to be documented, only forces documented
routes to stay accurate. That's a real gap, not a decision; it's acceptable for now because
the alternative (some kind of route-coverage lint) is more machinery than a solo project's
still-small API surface justifies.

## Revisit when

`openapi-typescript` ships a release whose `peerDependencies` accepts `typescript ^6.x` —
drop `--legacy-peer-deps` from both `npm install` usage and the `frontend` CI job's
`npm ci` step at that point, and confirm `@testing-library/dom` still resolves correctly
with the flag gone before removing its explicit pin.

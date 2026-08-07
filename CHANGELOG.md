# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are written for someone **operating the shop**, not for someone reading the diff.
Cite the `DESIGN.md` section a change implements.

<!--
Categories, in this order:
  Added       — new features
  Changed     — changes to existing behavior
  Deprecated  — soon-to-be-removed features
  Removed     — removed features
  Fixed       — bug fixes
  Security    — vulnerabilities and hardening
-->

## [Unreleased]

### Added

- Containerized development environment (§12 step 0): `docker compose` runs Postgres,
  Redis, the Rails API, a Sidekiq worker, and the Vite dev server. The `api` and `worker`
  services run the same image with different commands, matching the production topology
  (§14.1).
- Production images for both `boba-api` (multi-stage, non-root) and `boba-frontend`
  (Vite build served by nginx), per §14.1.
- Rails 8.1 API application on PostgreSQL and Redis, with Sidekiq for background work —
  no Solid Queue/Cache/Cable and no Kamal, per the design's locked Rails 8 note.
- React 19 + TypeScript + Tailwind v4 frontend, with kiosk (64px) and web (44px) hit-target
  minimums defined as theme tokens (§9.3, ADR-0003).
- Test infrastructure: RSpec, FactoryBot, shoulda-matchers, and the ADR-0002 coverage
  gates enforced in-process; Vitest and Testing Library for the frontend.
- Ruby and Node versions pinned in `.ruby-version` and `.node-version`, read by mise
  locally, by CI, and by both Dockerfiles.

### Changed

- ActionCable now uses the Redis adapter in development as well as production. The async
  adapter is single-process, so it would work locally and silently fail across the two
  `web` pods the design runs from the first deploy (§14.4).
- `bin/docker-entrypoint` no longer runs `db:prepare` on boot. Migrations belong to the
  `migrate` Job applied before each rollout (§14.2).
- DESIGN.md's stack line now reads React 19 rather than React 18. Nothing in the design
  depends on the version, and shadcn/Radix — which ADR-0003 commits to — target 19.

- Project workflow scaffolding: `CLAUDE.md`, PR template, ADR log, testing conventions,
  and this changelog.
- CI pipeline running rubocop, RSpec with coverage gates, and the frontend lint/type/test
  suite. Jobs are guarded on the files they need, so CI is green until the app lands (§12).
- Git hooks via lefthook: conventional-commit validation, lint autocorrect on staged files,
  and a guard against committing secret files (§14.6).
- Quality-gate decisions recorded in [ADR-0002](docs/adr/0002-quality-gates.md): SimpleCov
  thresholds, mutation testing scoped to the scheduler, rswag-generated API docs.
- Frontend styling decision recorded in
  [ADR-0003](docs/adr/0003-tailwind-with-shadcn-as-needed.md): Tailwind project-wide from
  build step 1, with shadcn/ui components pulled in individually where they earn their
  place (§9.3, §10.6).

[Unreleased]: https://github.com/tuvo1106/boba-gals/compare/HEAD...HEAD

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

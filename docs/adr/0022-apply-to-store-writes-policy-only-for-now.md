# ADR-0022: "Apply to store" writes `policy` only, for now

- **Status:** Accepted
- **Date:** 2026-08-13
- **Design reference:** DESIGN.md §10.6

## Context

§10.6 draws a CONFIG rail with seven knobs — demand, stations, policy, quantum, aging,
cohesion, large % — and says to "ship an 'Apply to store' action that writes the current
config to `stores.scheduler_config`, with a confirmation showing the diff."

The backend for this already existed before this change: `PATCH /api/v1/admin/scheduler_config`
and `UpdateSchedulerConfig::SCHEMA` accept nine live-tunable keys (`policy`, `quantum`,
`aging_enabled`, `aging_rate`, `cohesion_enabled`, `cohesion_boost`, `remake_multiplier`,
`promise_buffer`, `quality_limit_seconds`, `eta_safety_factor`), fully tested in
`spec/requests/api/v1/admin_spec.rb`. What did not exist was the dashboard button.

The dashboard's actual rail, though, only lets an operator adjust `policy` — `demand` and
`stations` are simulator-only inputs with no live counterpart (§10.1's arrival model and a
store's staffing are not scheduler tuning), and `quantum`/`aging`/`cohesion` are explored only
inside the one-off sweep and ablation experiments, never as persistent controls. That gap was
itself a deliberate, already-documented choice (`DashboardScreen.tsx`'s comment on `stations`/
`demand`: "the ablation toggles \[quantum, aging, cohesion\] wait on common random numbers").

So "write the current config" is ambiguous today: the rail's only piece of config-shaped state
is `policy`.

## Decision

**"Apply to store" writes `policy` only.** Quantum, aging, and cohesion sliders are not added
to the rail as part of this change — they stay experiment-only, and applying them to a store
waits until they exist as persistent rail controls, which is separate scope from wiring up an
already-built endpoint.

`rr` and `sjf` never reach the confirm step: the button disables itself with an explanatory
title when either is selected, rather than letting an operator confirm a write the server was
always going to refuse.

## Consequences

- An operator who has been exploring a quantum value in the sweep chart has no one-click way
  to ship it — they still need `PATCH /api/v1/admin/scheduler_config` by hand (curl, or a
  future rail control) for anything besides policy. This is a real gap, not a hidden one: the
  live-store box only ever claims to reflect `policy`.
- Extending the rail with quantum/aging/cohesion controls is a natural, larger follow-up. When
  it lands, `ApplyToStore` in `DashboardScreen.tsx` is the seam — it already reads from
  `SchedulerConfig` and diffs against `liveConfig`, so adding a field there is additive rather
  than a rewrite.

## Alternatives considered

| Option | Why not |
|---|---|
| **Add quantum/aging/cohesion sliders now, apply all of it** | Matches §10.6's mockup exactly, but is meaningfully more UI than "wire up the button" — new controls, new state, new diff rendering per field. Asked directly; the answer was to ship the thin version now. |
| **Apply the ablation/sweep's last-explored values implicitly** | Would let "Apply to store" write a quantum nobody deliberately chose on the rail itself — the ablation and sweep are comparisons across many configs, not a persistent "current" one, so there is no single value to point at without inventing a selection the operator never made. |

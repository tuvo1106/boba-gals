// Payload shapes from the Rails API. Every export below except `Policy` is a
// thin re-export of a schema generated from the request specs into
// generated.ts (ADR-0002, ADR-0030) — run `npm run generate:types` to
// regenerate after `docs/api/openapi.yaml` changes, never hand-edit
// generated.ts itself. This file exists so every call site keeps importing
// these exact names from this exact path; it is the one place allowed to
// diverge from the generated output, and only for `Policy`.
import type { components } from './generated'

/** A row in the board's Making column (DESIGN.md §9.2, §9.5). */
export type MakingRow = components['schemas']['MakingRow']

/** A row in the board's Ready column (§9.2, §9.5). */
export type ReadyRow = components['schemas']['ReadyRow']

/**
 * The whole board. Snapshots, not deltas (§9.2) — a client that misses a
 * message renders the next one correctly rather than drifting.
 */
export type BoardUpdate = components['schemas']['BoardUpdate']

/** One dispatched drink, as the lane ribbon places it (§10.6). */
export type TimelineDrink = components['schemas']['TimelineDrink']

/**
 * §6.3. `rr` and `sjf` are simulator-only comparison arms.
 *
 * Not generated: no single response schema is this union. It is strictly
 * broader than `SchedulerConfig['policy']`, which `UpdateSchedulerConfig::SCHEMA`
 * narrows to `drr`/`fifo` — a live store can never actually hold `rr` or `sjf`.
 */
export type Policy = 'drr' | 'fifo' | 'rr' | 'sjf'

/**
 * `stores.scheduler_config`, effective rather than raw (§6.6, §10.6) — every
 * key present even if the store never set it, matching
 * `Store#effective_scheduler_config` server-side. `policy` is narrower here
 * than `Policy`: `UpdateSchedulerConfig::SCHEMA` refuses `rr` and `sjf`, so a
 * live store can never actually hold one.
 */
export type SchedulerConfig = components['schemas']['SchedulerConfig']

/** The response from GET/PATCH /api/v1/admin/scheduler_config (§10.6). */
export type SchedulerConfigResponse = components['schemas']['SchedulerConfigResponse']

/** What a run reports (§10.4). Shared by a single run and by each ablation arm. */
export type SimulationMetrics = components['schemas']['SimulationMetrics']

/** The response from POST /api/v1/admin/simulations (§9.1). */
export type SimulationRun = components['schemas']['SimulationRun']

/** One drink on the kitchen display (§9.4). Mirrors `KitchenQueue.serialize`. */
export type KdsItem = components['schemas']['KdsItem']

/** The `queue_update` payload (§9.2, §9.4). A whole snapshot, never a delta. */
export type QueueUpdate = components['schemas']['QueueUpdate']

/** §9.4: "Fail/remake requires a reason tap (spill, wrong order, quality)." */
export type FailReason = components['schemas']['FailReason']

export type KdsSession = components['schemas']['KdsSession']

/** One choice within an option group (§9.1). */
export type MenuOption = components['schemas']['MenuOption']

/**
 * A set of choices attached to a drink (§9.1).
 *
 * `min_select`/`max_select` decide which control the ordering UI renders: a
 * radio group when at most one may be chosen, a checkbox set otherwise
 * (ADR-0003). They travel to the client for exactly that reason.
 */
export type OptionGroup = components['schemas']['OptionGroup']

export type MenuItem = components['schemas']['MenuItem']

/** GET /api/v1/menu. */
export type Menu = components['schemas']['Menu']

/** §5.1. */
export type OrderStatus = components['schemas']['OrderStatus']

/** §5.1. `finished` is terminal — a remake is a new row, not a reopened one. */
export type DrinkStatus = components['schemas']['DrinkStatus']

export type PlacedOrderItem = components['schemas']['PlacedOrderItem']

/**
 * An order as `POST /orders` and `GET /orders/:pickup_code` return it. Mirrors
 * `OrderSerializer` — note the absence of `customer_phone`, which is by
 * construction rather than by omission (§13.5).
 */
export type PlacedOrder = components['schemas']['PlacedOrder']

/** The `order_update` payload (§9.2). A whole snapshot, never a delta. */
export type OrderUpdate = components['schemas']['OrderUpdate']

/**
 * The one admin user (§13.4). No roles, no signup — created by seed or console.
 *
 * Carries the email and nothing else, matching what the server serializes. A
 * dashboard that knew more about the admin than it displays would be a payload
 * with no reason to exist.
 */
export type AdminUser = components['schemas']['AdminUser']

/** One arm of the ablation — the same day with one more mechanism turned on. */
export type AblationArm = components['schemas']['AblationArm']

/** The response from POST /api/v1/admin/ablations (§10.5). */
export type Ablation = components['schemas']['Ablation']

/** One quantum tried, and what a day looked like at it (§10.5 #2). */
export type QuantumSweepPoint = components['schemas']['QuantumSweepPoint']

/** The response from POST /api/v1/admin/quantum_sweeps (§10.5 #2). */
export type QuantumSweep = components['schemas']['QuantumSweep']

/**
 * One open hour's answer: the fewest stations, of the eight tried, whose p90
 * for orders arriving that hour cleared `target_seconds` (§10.5 #3).
 */
export type StaffingCurveHour = components['schemas']['StaffingCurveHour']

/** The response from POST /api/v1/admin/staffing_curves (§10.5 #3). */
export type StaffingCurve = components['schemas']['StaffingCurve']

/** One demand multiplier tried, and what a day looked like at it (§10.5 #4). */
export type BreakingPointPoint = components['schemas']['BreakingPointPoint']

/** The response from POST /api/v1/admin/breaking_points (§10.5 #4). */
export type BreakingPoint = components['schemas']['BreakingPoint']

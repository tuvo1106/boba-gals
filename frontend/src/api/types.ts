// Payload shapes from the Rails API, hand-written and kept in step by hand.
//
// ADR-0002 expected rswag to generate an OpenAPI document from the request
// specs at build step 4, and these types to be checked against it. Step 4
// shipped without it — rswag is not in the Gemfile and `docs/api/` does not
// exist — so nothing verifies that a type here matches what the server sends
// except a test failing. Adding a required field to a shared type means
// updating every hand-built fixture of it; grep the test files rather than
// trusting one suite run.

/** A row in the board's Making column (DESIGN.md §9.2, §9.5). */
export interface MakingRow {
  first_name: string | null
  pickup_code: string
  items: string[]
  eta_seconds: number
}

/** A row in the board's Ready column (§9.2, §9.5). */
export interface ReadyRow {
  first_name: string | null
  pickup_code: string
  ready_since_seconds: number
  /** Always null while pickup is untracked (ADR-0005). */
  picked_up_seconds_ago: number | null
}

/**
 * The whole board. Snapshots, not deltas (§9.2) — a client that misses a
 * message renders the next one correctly rather than drifting.
 */
export interface BoardUpdate {
  type: 'board_update'
  /** Which store to subscribe to. v1 resolves it server-side (§16). */
  store_id: number
  making: MakingRow[]
  ready: ReadyRow[]
}

/** One dispatched drink, as the lane ribbon places it (§10.6). */
export interface TimelineDrink {
  order_id: number
  drink_id: string
  station: number
  started_at: number
  finished_at: number | null
  prep_seconds: number
  remake: boolean
  order_size: number
}

/** §6.3. `rr` and `sjf` are simulator-only comparison arms. */
export type Policy = 'drr' | 'fifo' | 'rr' | 'sjf'

/**
 * `stores.scheduler_config`, effective rather than raw (§6.6, §10.6) — every
 * key present even if the store never set it, matching
 * `Store#effective_scheduler_config` server-side. `policy` is narrower here
 * than `Policy`: `UpdateSchedulerConfig::SCHEMA` refuses `rr` and `sjf`, so a
 * live store can never actually hold one.
 */
export interface SchedulerConfig {
  policy: 'drr' | 'fifo'
  quantum: number
  aging_enabled: boolean
  aging_rate: number
  cohesion_enabled: boolean
  cohesion_boost: number
  remake_multiplier: number
  promise_buffer: number
  quality_limit_seconds: number
  eta_safety_factor: number
}

/** The response from GET/PATCH /api/v1/admin/scheduler_config (§10.6). */
export interface SchedulerConfigResponse {
  store_id: number
  scheduler_config: SchedulerConfig
  /** `UpdateSchedulerConfig::SCHEMA`'s keys — what a PATCH may name. */
  editable: string[]
}

/** What a run reports (§10.4). Shared by a single run and by each ablation arm. */
export interface SimulationMetrics {
  orders: number
  drinks: number
  station_utilisation: number
  reneged: number
  remakes: number
  /** "Does your wait depend on what you ordered?" — 1.0 means no (§6.1). */
  wait_by_drink_cost: {
    cheap: { orders: number; p90: number }
    dear: { orders: number; p90: number }
    /** False when either side is too small to support the comparison. */
    comparable: boolean
    ratio: number
  }
  /**
   * What the customer was told, against what happened (§10.4, §7.3).
   *
   * Absolute error and bias answer different questions and §10.4 asks for
   * both: a shop that beats its quote on half of orders and is four minutes
   * late on the rest has a fine median error and a trust problem. `bias` is
   * signed — positive means late.
   */
  eta_accuracy: {
    /** Orders with a usable error. Excludes capped quotes. */
    orders: number
    /** Quotes that hit the projection horizon, so they are a floor not an estimate. */
    capped: number
    /** False when too few orders to treat these as percentiles. */
    measurable: boolean
    p50_abs: number
    p90_abs: number
    bias: number
  }
  quality_breach_rate: number
  /** The same, over multi-drink orders only — where cohesion is judged (§6.4, §9.6). */
  quality_breach_rate_multi: number
  wait_seconds: { p50: number; p90: number; p99: number }
  by_size_class: Record<string, { orders: number; p90_meaningful: boolean; p50: number; p90: number; p99: number }>
}

/** The response from POST /api/v1/admin/simulations (§9.1). */
export interface SimulationRun {
  seed: number
  stations: number
  window: { from: number; to: number }
  timeline: TimelineDrink[]
  /** `[order_id, first_start, last_finish, size]` for every order made, by start time. */
  order_spans: [number, number, number, number][]
  metrics: SimulationMetrics
}


/** One drink on the kitchen display (§9.4). Mirrors `KitchenQueue.serialize`. */
export interface KdsItem {
  id: number
  label: string
  status: 'queued' | 'in_progress' | 'finished'
  prep_seconds: number
  pickup_code: string
  /**
   * Position within its order — rendered "2 of 5" so a barista can see it is
   * part of a larger order.
   *
   * Not the `sequence` column: a remake is appended after every existing drink
   * (§5.2), so the column counts drinks that failed and renders a spilled
   * two-drink order as "2 of 3". Both numbers here count only the drinks the
   * order is still for.
   */
  position: number
  order_size: number
  remake: boolean
  station_id: number | null
  started_at: string | null
}

/** The `queue_update` payload (§9.2, §9.4). A whole snapshot, never a delta. */
export interface QueueUpdate {
  type: 'queue_update'
  in_progress: KdsItem[]
  next_up: KdsItem[]
  depth: number
  oldest_waiting_seconds: number
}

/** §9.4: "Fail/remake requires a reason tap (spill, wrong order, quality)." */
export type FailReason = 'spill' | 'wrong_order' | 'quality'

export interface KdsSession {
  token: string
  expires_in: number
  barista: { id: number; name: string }
  station: { id: number; name: string }
  /** Needed to subscribe — KitchenChannel rejects a store_id that does not match the token. */
  store: { id: number; name: string }
}

/** One choice within an option group (§9.1). */
export interface MenuOption {
  id: number
  name: string
  price_cents: number
  prep_seconds_delta: number
}

/**
 * A set of choices attached to a drink (§9.1).
 *
 * `min_select`/`max_select` decide which control the ordering UI renders: a
 * radio group when at most one may be chosen, a checkbox set otherwise
 * (ADR-0003). They travel to the client for exactly that reason.
 */
export interface OptionGroup {
  id: number
  name: string
  min_select: number
  max_select: number
  options: MenuOption[]
}

export interface MenuItem {
  id: number
  name: string
  category: string
  price_cents: number
  base_prep_seconds: number
  option_groups: OptionGroup[]
}

/** GET /api/v1/menu. */
export interface Menu {
  items: MenuItem[]
}

/** §5.1. */
export type OrderStatus =
  | 'draft' | 'placed' | 'in_progress' | 'partially_ready'
  | 'ready' | 'picked_up' | 'abandoned' | 'cancelled'

/** §5.1. `finished` is terminal — a remake is a new row, not a reopened one. */
export type DrinkStatus = 'queued' | 'in_progress' | 'finished' | 'failed' | 'cancelled'

export interface PlacedOrderItem {
  id: number
  label: string
  status: DrinkStatus
  prep_seconds: number
  sequence: number
  remake: boolean
}

/**
 * An order as `POST /orders` and `GET /orders/:pickup_code` return it. Mirrors
 * `OrderSerializer` — note the absence of `customer_phone`, which is by
 * construction rather than by omission (§13.5).
 */
export interface PlacedOrder {
  pickup_code: string
  status: OrderStatus
  source: 'kiosk' | 'web'
  customer_first_name: string | null
  placed_at: string
  promised_at: string | null
  ready_at: string | null
  total_cents: number
  quoted_wait_seconds: number
  items: PlacedOrderItem[]
}

/** The `order_update` payload (§9.2). A whole snapshot, never a delta. */
export interface OrderUpdate {
  type: 'order_update'
  pickup_code: string
  status: OrderStatus
  eta_seconds: number
  items: { id: number; label: string; status: DrinkStatus }[]
}

/**
 * The one admin user (§13.4). No roles, no signup — created by seed or console.
 *
 * Carries the email and nothing else, matching what the server serializes. A
 * dashboard that knew more about the admin than it displays would be a payload
 * with no reason to exist.
 */
export interface AdminUser {
  email: string
}

/** One arm of the ablation — the same day with one more mechanism turned on. */
export interface AblationArm {
  id: string
  /**
   * Which of the three things this row is (§6.3): the `control` everything is
   * measured against, a `rung` on the ladder, or a `bound` — SJF, which is a
   * benchmark and never a policy. The chart draws bounds apart from the ladder
   * because reading SJF as "the best row" is the specific misreading §6.3 warns
   * about, and on the size-class axis it genuinely is the best row.
   */
  kind: 'control' | 'rung' | 'bound'
  label: string
  blurb: string
  /**
   * Customers who walked in. Identical across arms by construction (ADR-0011),
   * which is what makes the comparison an experiment — while `metrics.orders`
   * may legitimately differ, because a slower arm drives more people away
   * before they order (§10.3).
   */
  arrived: number
  metrics: SimulationMetrics
}

/** The response from POST /api/v1/admin/ablations (§10.5). */
export interface Ablation {
  seed: number
  /** Days pooled per arm. One is §10.5's fixed seed; more is how you tell a
   *  real difference from one unlucky Tuesday. */
  seeds: number
  stations: number
  demand_multiplier: number
  quantum: number | null
  arms: AblationArm[]
}

/** One quantum tried, and what a day looked like at it (§10.5 #2). */
export interface QuantumSweepPoint {
  quantum: number
  /** Customers who walked in — identical across every point (ADR-0011). */
  arrived: number
  metrics: SimulationMetrics
}

/** The response from POST /api/v1/admin/quantum_sweeps (§10.5 #2). */
export interface QuantumSweep {
  seed: number
  seeds: number
  stations: number
  demand_multiplier: number
  /** Ten points, ascending — `Simulator::QuantumSweep::POINTS`. */
  points: QuantumSweepPoint[]
}

/**
 * One open hour's answer: the fewest stations, of the eight tried, whose p90
 * for orders arriving that hour cleared `target_seconds` (§10.5 #3).
 */
export interface StaffingCurveHour {
  /** Shop-clock hour, 10–20 — matches `clock.ts`'s `OPENS_AT`. */
  hour: number
  stations: number
  /** False means every count up to `Simulator::StaffingCurve::STATIONS_TRIED`'s
   *  ceiling still missed the target — `stations` is the ceiling, not an answer. */
  achieved: boolean
  p90: number
  orders: number
  p90_meaningful: boolean
}

/** The response from POST /api/v1/admin/staffing_curves (§10.5 #3). */
export interface StaffingCurve {
  seed: number
  seeds: number
  demand_multiplier: number
  target_seconds: number
  /** Eleven hours, ascending — one per §10.3's arrival profile. */
  hours: StaffingCurveHour[]
}

/** One demand multiplier tried, and what a day looked like at it (§10.5 #4). */
export interface BreakingPointPoint {
  demand_multiplier: number
  /** Customers who walked in. Unlike `Ablation`/`QuantumSweep`, this is *not*
   *  expected to match across points — demand_multiplier scales the arrival
   *  intensity itself (§10.1), so a higher point sees more customers by
   *  construction. */
  arrived: number
  metrics: SimulationMetrics
}

/** The response from POST /api/v1/admin/breaking_points (§10.5 #4). */
export interface BreakingPoint {
  seed: number
  seeds: number
  stations: number
  target_seconds: number
  /** Points, ascending — `Simulator::BreakingPoint::POINTS`. */
  points: BreakingPointPoint[]
  /** The first demand multiplier whose overall p90 crossed `target_seconds` —
   *  the shop's real capacity. Null when nothing in `points` crossed it, the
   *  ceiling of what was tried rather than an answer. */
  capacity: number | null
}

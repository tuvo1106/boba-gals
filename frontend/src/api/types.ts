// Payload shapes from the Rails API. Hand-written for now; build step 4 brings
// rswag-generated docs (ADR-0002) and these should be checked against them.

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

/** The response from POST /api/v1/admin/simulations (§9.1). */
/** §6.3. `rr` and `sjf` are simulator-only comparison arms. */
export type Policy = 'drr' | 'fifo' | 'rr' | 'sjf'

export interface SimulationRun {
  seed: number
  stations: number
  window: { from: number; to: number }
  timeline: TimelineDrink[]
  /** `[order_id, first_start, last_finish, size]` for every order made, by start time. */
  order_spans: [number, number, number, number][]
  metrics: {
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
    quality_breach_rate: number
    /** The same, over multi-drink orders only — where cohesion is judged (§6.4, §9.6). */
    quality_breach_rate_multi: number
    wait_seconds: { p50: number; p90: number; p99: number }
    by_size_class: Record<string, { orders: number; p90_meaningful: boolean; p50: number; p90: number; p99: number }>
  }
}


/** One drink on the kitchen display (§9.4). Mirrors `KitchenQueue.serialize`. */
export interface KdsItem {
  id: number
  label: string
  status: 'queued' | 'in_progress' | 'finished'
  prep_seconds: number
  pickup_code: string
  /** Position within its order — rendered "2 of 5" so a barista can see it is part of a larger order. */
  sequence: number
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

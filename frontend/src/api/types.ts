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

export interface KdsSession {
  token: string
  expires_in: number
  barista: { id: number; name: string }
  station: { id: number; name: string }
}

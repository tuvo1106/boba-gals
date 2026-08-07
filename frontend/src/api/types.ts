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

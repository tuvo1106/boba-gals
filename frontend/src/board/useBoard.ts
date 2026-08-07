import { useCallback, useEffect, useRef, useState } from 'react'
import { apiGet } from '../api/client'
import { subscribe } from '../api/cable'
import type { BoardUpdate, MakingRow, ReadyRow } from '../api/types'

/**
 * §9.5: "Items persist for 90 seconds after `picked_up_at`." Mirrors
 * BoardView::PICKED_UP_PERSISTENCE.
 */
export const PICKED_UP_PERSISTENCE_SECONDS = 90

/**
 * A ready row is retired five minutes after it went ready (ADR-0005). Mirrors
 * BoardView::READY_BOARD_TTL.
 *
 * The server applies both windows too — this is not the source of truth, it is
 * what keeps the screen honest between broadcasts. A quiet store can go minutes
 * without a transition, and a name that should have gone is worse than a name
 * that arrives a second late.
 */
export const READY_BOARD_TTL_SECONDS = 300

export type ConnectionState = 'connecting' | 'live' | 'offline'

interface Board {
  making: MakingRow[]
  ready: ReadyRow[]
  connection: ConnectionState
}

/** Ages a snapshot forward by `elapsed` seconds and drops rows that expired. */
export function age(board: BoardUpdate, elapsed: number): Pick<Board, 'making' | 'ready'> {
  return {
    making: board.making.map((row) => ({
      ...row,
      // Never below zero: a negative countdown is the board admitting it was
      // wrong, which is worse than sitting at "Almost ready" until the drink
      // actually lands.
      eta_seconds: Math.max(0, row.eta_seconds - elapsed),
    })),
    ready: board.ready
      .map((row) => ({
        ...row,
        ready_since_seconds: row.ready_since_seconds + elapsed,
        picked_up_seconds_ago:
          row.picked_up_seconds_ago === null ? null : row.picked_up_seconds_ago + elapsed,
      }))
      .filter((row) =>
        row.picked_up_seconds_ago !== null
          ? row.picked_up_seconds_ago <= PICKED_UP_PERSISTENCE_SECONDS
          : row.ready_since_seconds <= READY_BOARD_TTL_SECONDS,
      ),
  }
}

/**
 * The customer board (§9.2, §9.5): one REST read for first paint, then live
 * snapshots over ActionCable, aged locally once a second in between.
 */
export function useBoard(): Board {
  const [snapshot, setSnapshot] = useState<BoardUpdate | null>(null)
  const [connection, setConnection] = useState<ConnectionState>('connecting')
  const [now, setNow] = useState(() => Date.now())
  const receivedAt = useRef(Date.now())

  const receive = useCallback((update: BoardUpdate) => {
    receivedAt.current = Date.now()
    setNow(Date.now())
    setSnapshot(update)
  }, [])

  useEffect(() => {
    const controller = new AbortController()

    apiGet<BoardUpdate>('/board', controller.signal)
      .then(receive)
      .catch(() => {
        // A failed first read is not fatal: the websocket sends a whole
        // snapshot on connect anyway (§9.2). Leaving the screen in
        // `connecting` is the honest state.
        if (!controller.signal.aborted) setConnection('offline')
      })

    return () => controller.abort()
  }, [receive])

  const storeId = snapshot?.store_id

  useEffect(() => {
    if (storeId === undefined) return

    return subscribe<BoardUpdate>({
      channel: 'BoardChannel',
      params: { store_id: storeId },
      onReceived: receive,
      onConnected: () => setConnection('live'),
      onDisconnected: () => setConnection('offline'),
    })
  }, [storeId, receive])

  useEffect(() => {
    const tick = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(tick)
  }, [])

  if (snapshot === null) return { making: [], ready: [], connection }

  return {
    ...age(snapshot, Math.floor((now - receivedAt.current) / 1000)),
    connection,
  }
}

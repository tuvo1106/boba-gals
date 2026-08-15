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

/**
 * How long to wait before retrying the board's first read.
 *
 * The board is a wall display — there is nobody to notice a dead screen and
 * reload it, so the first read has to recover on its own.
 */
export const RETRY_MS = 3_000

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
    let retry: ReturnType<typeof setTimeout> | undefined

    // **The first read has to keep trying.** The subscribe effect below is
    // gated on a `store_id`, and the only place that comes from is this
    // response — `BoardChannel#subscribed` rejects a subscription without one,
    // so there is no blind-subscribe fallback. A single failed read (the Rails
    // pod not ready when the screen opens, one blip) therefore used to leave
    // the board at "Reconnecting…" with empty columns until a human reloaded
    // it. Nobody reloads a screen on a wall.
    //
    // Retried at a fixed RETRY_MS rather than backing off: this is a display
    // that is supposed to be live all shift, and the request is one cheap read
    // against the same cluster.
    const read = () => {
      apiGet<BoardUpdate>('/board', controller.signal)
        .then(receive)
        .catch(() => {
          if (controller.signal.aborted) return

          setConnection('offline')
          retry = setTimeout(read, RETRY_MS)
        })
    }

    read()

    return () => {
      controller.abort()
      if (retry !== undefined) clearTimeout(retry)
    }
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

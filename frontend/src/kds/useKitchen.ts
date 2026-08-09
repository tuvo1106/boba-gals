import { useCallback, useEffect, useState } from 'react'
import { apiGetWithToken, apiPost } from '../api/client'
import { subscribe } from '../api/cable'
import type { KdsItem, KdsSession, QueueUpdate } from '../api/types'

/** §5.2: the undo window on the last action. Mirrors `UndoLastAction::WINDOW`. */
export const UNDO_WINDOW_SECONDS = 60

export type ConnectionState = 'connecting' | 'live' | 'offline'

/** The last thing this barista did, and how long they still have to take it back. */
export interface LastAction {
  item: KdsItem
  kind: 'started' | 'finished'
  secondsLeft: number
}

interface Kitchen {
  queue: QueueUpdate | null
  connection: ConnectionState
  error: string | null
  lastAction: LastAction | null
  start: () => Promise<void>
  finish: (item: KdsItem) => Promise<void>
  undo: () => Promise<void>
}

/**
 * Live kitchen queue for the KDS (§9.4).
 *
 * Two rules from §9.4 shape this. **No confirmation dialogs** — every action
 * fires on one tap, so the only protection against a mistap is the 60-second
 * undo, and the affordance for it has to be visible rather than remembered.
 * And the payload is a whole snapshot, never a delta (§9.2), so a client that
 * misses a broadcast simply renders the next one correctly and never has to
 * reconcile.
 *
 * @param session the station token from `POST /kds/session`
 */
export function useKitchen(session: KdsSession | null): Kitchen {
  const [queue, setQueue] = useState<QueueUpdate | null>(null)
  const [connection, setConnection] = useState<ConnectionState>('connecting')
  const [error, setError] = useState<string | null>(null)
  // Stored as the moment it happened rather than as a countdown, so the number
  // on screen is derived from the clock instead of being decremented — a tab
  // that is backgrounded and restored shows the truth rather than however many
  // ticks it managed to run.
  const [acted, setActed] = useState<{ item: KdsItem; kind: LastAction['kind']; at: number } | null>(null)
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (session === null) return

    let cancelled = false

    // The REST read is what fills the screen if the websocket is slow or
    // blocked; the channel transmits a snapshot on subscribe too, so whichever
    // lands first wins and the other is a harmless idempotent replacement.
    apiGetWithToken<QueueUpdate>('/kds/queue', session.token)
      .then((snapshot) => {
        if (!cancelled) setQueue(snapshot)
      })
      .catch(() => {
        if (!cancelled) setError('Could not load the queue')
      })

    const unsubscribe = subscribe<QueueUpdate>({
      channel: 'KitchenChannel',
      // The *store* id, not the station id. KitchenChannel rejects a mismatch
      // (§13.3), and passing the station id silently worked only for station 1
      // of store 1 — every other station sat at "connecting" forever.
      params: { token: session.token, store_id: session.store.id },
      onReceived: (payload) => {
        if (!cancelled) setQueue(payload)
      },
      onConnected: () => !cancelled && setConnection('live'),
      onDisconnected: () => !cancelled && setConnection('offline'),
    })

    return () => {
      cancelled = true
      unsubscribe()
    }
  }, [session])

  // The undo affordance expires on its own. A stale "Undo" button that fails
  // when tapped is worse than no button, because the barista has already
  // decided the mistake is fixable.
  useEffect(() => {
    if (acted === null) return

    const timer = setInterval(() => setNow(Date.now()), 1000)

    return () => clearInterval(timer)
  }, [acted])

  const secondsLeft = acted === null ? 0 : UNDO_WINDOW_SECONDS - Math.floor((now - acted.at) / 1000)
  const lastAction: LastAction | null =
    acted !== null && secondsLeft > 0 ? { item: acted.item, kind: acted.kind, secondsLeft } : null

  const remember = useCallback((item: KdsItem, kind: LastAction['kind']) => {
    setActed({ item, kind, at: Date.now() })
    setNow(Date.now())
  }, [])

  const act = useCallback(
    async (run: () => Promise<KdsItem>, kind: LastAction['kind'] | null) => {
      if (session === null) return

      setError(null)
      try {
        const item = await run()
        if (kind) remember(item, kind)
      } catch (e) {
        setError(e instanceof Error ? e.message : 'That did not work')
      }
    },
    [session, remember],
  )

  // `start` takes no id — the server picks the next drink, which is what lets
  // the scheduler decide rather than the barista, and what let DRR replace FIFO
  // at build step 5 without touching this client at all.
  const start = useCallback(
    () => act(() => apiPost<KdsItem>('/kds/items/start', {}, { token: session?.token }), 'started'),
    [act, session],
  )

  const finish = useCallback(
    (item: KdsItem) =>
      act(() => apiPost<KdsItem>(`/kds/items/${item.id}/finish`, {}, { token: session?.token }), 'finished'),
    [act, session],
  )

  // Depends on `acted`, the stable state, rather than on the derived
  // `lastAction`, which is a fresh object every render and would rebuild this
  // callback on every tick of the countdown.
  const undo = useCallback(async () => {
    if (acted === null) return

    await act(() => apiPost<KdsItem>(`/kds/items/${acted.item.id}/undo`, {}, { token: session?.token }), null)
    setActed(null)
  }, [act, acted, session])

  return { queue, connection, error, lastAction, start, finish, undo }
}

import { useCallback, useEffect, useState } from 'react'
import { ApiError, apiGetWithToken, apiPost } from '../api/client'
import { subscribe } from '../api/cable'
import type { FailReason, KdsItem, KdsSession, QueueUpdate } from '../api/types'

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
  /**
   * How long the drink that has waited longest has been waiting, counted
   * forward from the last snapshot rather than frozen at it (§9.4).
   */
  oldestWaitingSeconds: number
  lastAction: LastAction | null
  start: () => Promise<void>
  finish: (item: KdsItem) => Promise<void>
  fail: (item: KdsItem, reason: FailReason) => Promise<void>
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
 * @param onExpired called when the server rejects the token — a restored
 *   session outlives its 12-hour expiry (§13.3), and a screen that keeps
 *   showing a stale queue behind a dead token is worse than a sign-in prompt
 */
export function useKitchen(session: KdsSession | null, onExpired?: () => void): Kitchen {
  const [queue, setQueue] = useState<QueueUpdate | null>(null)
  // When that snapshot arrived, so `oldest_waiting_seconds` can be advanced
  // from it. Stored as an instant for the same reason the undo window is: the
  // number is derived from the clock rather than decremented, so a tablet that
  // slept through a shift change shows the truth instead of however many ticks
  // it managed to run.
  const [queuedAt, setQueuedAt] = useState(() => Date.now())
  const [connection, setConnection] = useState<ConnectionState>('connecting')
  const [error, setError] = useState<string | null>(null)
  // Stored as the moment it happened rather than as a countdown, so the number
  // on screen is derived from the clock instead of being decremented — a tab
  // that is backgrounded and restored shows the truth rather than however many
  // ticks it managed to run.
  const [acted, setActed] = useState<{ item: KdsItem; kind: LastAction['kind']; at: number } | null>(null)
  const [now, setNow] = useState(() => Date.now())

  // Every snapshot lands here, from either source, so the arrival instant the
  // header counts forward from is set in exactly one place.
  const receive = useCallback((snapshot: QueueUpdate) => {
    setQueue(snapshot)
    setQueuedAt(Date.now())
    setNow(Date.now())
  }, [])

  useEffect(() => {
    if (session === null) return

    let cancelled = false

    // The REST read is what fills the screen if the websocket is slow or
    // blocked; the channel transmits a snapshot on subscribe too, so whichever
    // lands first wins and the other is a harmless idempotent replacement.
    apiGetWithToken<QueueUpdate>('/kds/queue', session.token)
      .then((snapshot) => {
        if (!cancelled) receive(snapshot)
      })
      .catch((e: unknown) => {
        if (cancelled) return

        // A restored token that the server no longer accepts. Signing out is
        // the honest response — the alternative is an empty queue and a
        // "start next drink" button that 401s on every tap.
        if (e instanceof ApiError && e.status === 401) return onExpired?.()

        setError('Could not load the queue')
      })

    const unsubscribe = subscribe<QueueUpdate>({
      channel: 'KitchenChannel',
      // The *store* id, not the station id. KitchenChannel rejects a mismatch
      // (§13.3), and passing the station id silently worked only for station 1
      // of store 1 — every other station sat at "connecting" forever.
      params: { token: session.token, store_id: session.store.id },
      onReceived: (payload) => {
        if (!cancelled) receive(payload)
      },
      onConnected: () => !cancelled && setConnection('live'),
      onDisconnected: () => !cancelled && setConnection('offline'),
    })

    return () => {
      cancelled = true
      unsubscribe()
    }
  }, [session, receive, onExpired])

  // One second is the resolution of everything on this screen: the undo
  // countdown, and the oldest-wait clock in the header. A single interval runs
  // for the whole shift rather than being started and stopped per affordance —
  // the KDS is one tab open all day, and a re-render a second is nothing next
  // to what the websocket already causes.
  useEffect(() => {
    if (session === null) return

    const timer = setInterval(() => setNow(Date.now()), 1000)

    return () => clearInterval(timer)
  }, [session])

  // Frozen at zero when nothing is waiting: an empty queue has no oldest
  // drink, and ticking upward from nothing would invent a wait.
  const oldestWaitingSeconds =
    queue === null || queue.depth === 0
      ? 0
      : queue.oldest_waiting_seconds + Math.max(0, Math.floor((now - queuedAt) / 1000))

  const secondsLeft = acted === null ? 0 : UNDO_WINDOW_SECONDS - Math.floor((now - acted.at) / 1000)
  const lastAction: LastAction | null =
    acted !== null && secondsLeft > 0 ? { item: acted.item, kind: acted.kind, secondsLeft } : null

  const remember = useCallback((item: KdsItem, kind: LastAction['kind']) => {
    setActed({ item, kind, at: Date.now() })
    setNow(Date.now())
  }, [])

  // Returns whether the request actually succeeded. Only `undo` reads it, and
  // it has to: the failure is swallowed into `error` here rather than thrown,
  // so a caller that assumes completion is indistinguishable from one that
  // checked.
  const act = useCallback(
    async (run: () => Promise<KdsItem>, kind: LastAction['kind'] | null): Promise<boolean> => {
      if (session === null) return false

      setError(null)
      try {
        const item = await run()
        if (kind) remember(item, kind)
        return true
      } catch (e) {
        setError(e instanceof Error ? e.message : 'That did not work')
        return false
      }
    },
    [session, remember],
  )

  // `start` takes no id — the server picks the next drink, which is what lets
  // the scheduler decide rather than the barista, and what let DRR replace FIFO
  // at build step 5 without touching this client at all.
  const start = useCallback(async () => {
    await act(() => apiPost<KdsItem>('/kds/items/start', {}, { token: session?.token }), 'started')
  }, [act, session])

  const finish = useCallback(async (item: KdsItem) => {
    await act(() => apiPost<KdsItem>(`/kds/items/${item.id}/finish`, {}, { token: session?.token }), 'finished')
  }, [act, session])

  // Deliberately not remembered as a `lastAction`. Undo rewinds a mistap; a
  // remake records that a real drink was really made wrong (§5.2), and undoing
  // it would delete the evidence and leave the customer without a drink. A
  // barista who taps this by accident fails the remake in turn.
  const fail = useCallback(async (item: KdsItem, reason: FailReason) => {
    await act(() => apiPost<KdsItem>(`/kds/items/${item.id}/fail`, { reason }, { token: session?.token }), null)
  }, [ act, session ])

  // Depends on `acted`, the stable state, rather than on the derived
  // `lastAction`, which is a fresh object every render and would rebuild this
  // callback on every tick of the countdown.
  //
  // The affordance is cleared only when the undo actually landed. It used to be
  // cleared unconditionally, so a failed undo — an expired window, a dropped
  // request, a station signed out mid-tap — took the Undo button away and left
  // the barista holding an error message and no way to try again. §9.4 forbids
  // confirmation dialogs, which makes this button the *only* protection against
  // a mistap; removing it while the server still considers the drink undoable
  // is removing the one guard the design leaves in place.
  const undo = useCallback(async () => {
    if (acted === null) return

    const undone = await act(
      () => apiPost<KdsItem>(`/kds/items/${acted.item.id}/undo`, {}, { token: session?.token }),
      null,
    )
    if (undone) setActed(null)
  }, [act, acted, session])

  return { queue, connection, error, oldestWaitingSeconds, lastAction, start, finish, fail, undo }
}

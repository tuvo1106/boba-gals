import { useEffect, useState } from 'react'
import { apiGet } from '../api/client'
import { subscribe } from '../api/cable'
import type { DrinkStatus, OrderStatus, OrderUpdate, PlacedOrder } from '../api/types'

export interface OrderProgress {
  pickupCode: string
  status: OrderStatus
  etaSeconds: number
  items: { id: number; label: string; status: DrinkStatus }[]
}

interface Watched {
  order: PlacedOrder | null
  progress: OrderProgress | null
  error: string | null
}

/**
 * Watches one order for the customer who placed it (§9.2).
 *
 * Two sources, deliberately. `GET /orders/:pickup_code` supplies the parts that
 * never change — what was ordered, what it cost — and `OrderChannel` supplies
 * the parts that do. The REST read is also what fills the screen if the
 * websocket is slow or blocked, and the channel transmits a snapshot on
 * subscribe, so whichever lands first wins and the other is a harmless
 * idempotent replacement (§9.2).
 *
 * @param pickupCode the capability token the customer is holding (§13.1)
 * @param seed the order as `POST /orders` returned it, when this screen was
 *   reached by placing it — skips a round trip and avoids a blank first frame
 */
export function useOrderStatus(pickupCode: string, seed: PlacedOrder | null = null): Watched {
  const [order, setOrder] = useState<PlacedOrder | null>(seed)
  const [progress, setProgress] = useState<OrderProgress | null>(
    seed ? fromOrder(seed) : null,
  )
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false

    apiGet<PlacedOrder>(`/orders/${pickupCode}`)
      .then((fetched) => {
        if (cancelled) return

        setOrder(fetched)
        // Only seeds the live view; a broadcast that already arrived is
        // fresher than this read and must not be rolled back by it.
        setProgress((current) => current ?? fromOrder(fetched))
      })
      .catch(() => {
        if (!cancelled) setError('We could not find that order.')
      })

    const unsubscribe = subscribe<OrderUpdate>({
      channel: 'OrderChannel',
      // The code is the whole credential (§13.1). There is no token to pass and
      // deliberately so — a customer holding a receipt can reopen this on any
      // device without an account (§9.3 is guest-only in v1).
      params: { pickup_code: pickupCode },
      onReceived: (payload) => {
        if (cancelled) return

        setProgress({
          pickupCode: payload.pickup_code,
          status: payload.status,
          etaSeconds: payload.eta_seconds,
          items: payload.items,
        })
      },
    })

    return () => {
      cancelled = true
      unsubscribe()
    }
  }, [pickupCode])

  return { order, progress, error }
}

function fromOrder(order: PlacedOrder): OrderProgress {
  return {
    pickupCode: order.pickup_code,
    status: order.status,
    etaSeconds: order.quoted_wait_seconds,
    items: order.items.map(({ id, label, status }) => ({ id, label, status })),
  }
}

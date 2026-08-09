import { useEffect, useState } from 'react'
import { apiGet } from '../api/client'

/** §9.3: "the kiosk polls `/api/v1/health` every 10s". */
export const POLL_INTERVAL_MS = 10_000

/**
 * §9.3, locked: "Two consecutive failures → full-screen state."
 *
 * Two rather than one because a single dropped request on shop wifi is normal,
 * and a kiosk that refuses to sell on every blip costs more than one that takes
 * ten extra seconds to notice a real outage.
 */
export const FAILURES_BEFORE_PAUSED = 2

/**
 * `checking` is the first-load state and is not a refusal. Rendering one before
 * the first response has landed would flash "Ordering is paused" on every boot,
 * which is exactly the screen a customer should never see wrongly.
 *
 * `unreachable` and `not_accepting` both stop ordering but are *different
 * facts*, and the screen says so. Telling a customer "the kiosk can't reach the
 * store system" when the owner deliberately turned ordering off is untrue, and
 * it sends staff to debug wifi that is working. Found by driving both against
 * the compose stack.
 */
export type HealthState = 'checking' | 'live' | 'unreachable' | 'not_accepting'

/** Whether this state stops a customer ordering, whatever the reason. */
export function blocksOrdering(state: HealthState): boolean {
  return state === 'unreachable' || state === 'not_accepting'
}

interface Health {
  accepting_orders: boolean
  store_name: string
}

/**
 * The kiosk's connectivity probe (§9.3, locked in §3).
 *
 * `/api/v1/health` is deliberately a *business* check, not a liveness one — it
 * answers "is the store taking orders", which includes `stores.accepting_orders`
 * (`health_controller.rb`). So a 200 carrying `accepting_orders: false` pauses
 * too: `CreateOrder` would refuse that order anyway, and letting a customer
 * build a cart the server will reject is the worse outcome.
 *
 * Recovery is on the *first* success, unlike the two failures it takes to
 * pause. The asymmetry is deliberate — being slow to start selling again is a
 * cost with no upside, while being quick to stop is the whole point.
 *
 * @param enabled false for the web flow, which is a phone that already shows
 *   its own connectivity and has no attract screen to fall back to
 */
export function useHealth(enabled = true): HealthState {
  const [state, setState] = useState<HealthState>('checking')

  useEffect(() => {
    if (!enabled) return

    let cancelled = false
    // A ref would do, but this never reads across renders — it is the poll
    // loop's own counter and lives entirely inside the effect.
    let consecutiveFailures = 0

    async function check() {
      try {
        const health = await apiGet<Health>('/health')
        if (cancelled) return

        consecutiveFailures = 0
        setState(health.accepting_orders ? 'live' : 'not_accepting')
      } catch {
        if (cancelled) return

        consecutiveFailures += 1
        if (consecutiveFailures >= FAILURES_BEFORE_PAUSED) setState('unreachable')
      }
    }

    void check()
    const timer = setInterval(() => void check(), POLL_INTERVAL_MS)

    return () => {
      cancelled = true
      clearInterval(timer)
    }
  }, [enabled])

  return state
}

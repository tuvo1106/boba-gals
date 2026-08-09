import type { KdsSession } from '../api/types'

const KEY = 'boba_gals.kds_session'

/**
 * Where a signed-in station's token lives between page loads (§13.3).
 *
 * **`sessionStorage`, not `localStorage`, and not a cookie.**
 *
 * A cookie set from JavaScript is readable by JavaScript in exactly the same
 * way this is, so it buys no safety — and the token is a bearer credential,
 * sent as an `Authorization` header and as an `OrderChannel`/`KitchenChannel`
 * subscribe param (§13.3). Making it a cookie would mean a second transport
 * for the same secret. The version that *would* be safer is an `HttpOnly`
 * cookie set by the server, and that is a different design from §13.3's signed
 * token, not a tweak to this one.
 *
 * `localStorage` outlives the shift: the tablet is shared, and the next
 * barista would inherit the last one's session on a device that never closes
 * its browser. `sessionStorage` is scoped to the tab, so a refresh keeps the
 * shift and closing the tab ends it.
 *
 * Either way the token carries its own 12-hour expiry (§13.3) and the server
 * is the thing that decides — this is a convenience, never an authority.
 */
export function readSession(): KdsSession | null {
  try {
    const raw = sessionStorage.getItem(KEY)
    if (raw === null) return null

    const parsed: unknown = JSON.parse(raw)

    // A hand-edited or half-written entry must not crash the sign-in screen —
    // a barista cannot open devtools to clear it, and this is the screen the
    // shop runs on.
    return isSession(parsed) ? parsed : null
  } catch {
    return null
  }
}

export function writeSession(session: KdsSession): void {
  try {
    sessionStorage.setItem(KEY, JSON.stringify(session))
  } catch {
    // Private browsing, a full quota, storage disabled by policy. The shift
    // still works; it just will not survive a refresh.
  }
}

export function clearSession(): void {
  try {
    sessionStorage.removeItem(KEY)
  } catch {
    // See writeSession.
  }
}

function isSession(value: unknown): value is KdsSession {
  if (typeof value !== 'object' || value === null) return false

  const candidate = value as Partial<KdsSession>

  return (
    typeof candidate.token === 'string' &&
    typeof candidate.station?.id === 'number' &&
    typeof candidate.store?.id === 'number' &&
    typeof candidate.barista?.name === 'string'
  )
}

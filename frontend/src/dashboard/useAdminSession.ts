import { useCallback, useEffect, useState } from 'react'
import { apiDelete, apiGet, apiPost } from '../api/client'
import type { AdminUser } from '../api/types'

/**
 * Three states, not two. `checking` is the one that is easy to leave out and
 * the one a signed-in admin sees most often: the session lives in a cookie the
 * page cannot read, so every load has to ask the server. Collapsing `checking`
 * into `signed_out` flashes a sign-in form at someone who is already signed in,
 * on every single reload.
 *
 * The kiosk's health check has the same shape and the same first state for the
 * same reason (§9.3).
 */
export type AdminSession =
  | { status: 'checking' }
  | { status: 'signed_out' }
  | { status: 'signed_in'; admin: AdminUser }

/**
 * Who the dashboard is talking to (§13.4).
 *
 * The cookie is `HttpOnly` and `SameSite=Strict` (ADR-0006), so there is
 * nothing in the document to inspect — `GET /admin/session` is the only way to
 * answer "am I signed in", and it exists for exactly this.
 */
export function useAdminSession() {
  const [session, setSession] = useState<AdminSession>({ status: 'checking' })

  useEffect(() => {
    const controller = new AbortController()

    apiGet<AdminUser>('/admin/session', controller.signal)
      .then((admin) => setSession({ status: 'signed_in', admin }))
      .catch(() => {
        // Any failure lands on the form: a 401 because that is what it means,
        // and anything else because a dashboard nobody can authenticate to is
        // not usefully different. The reason surfaces on the next sign-in
        // attempt, which is when someone is in a position to act on it.
        if (!controller.signal.aborted) setSession({ status: 'signed_out' })
      })

    return () => controller.abort()
  }, [])

  const signIn = useCallback(async (email: string, password: string) => {
    const admin = await apiPost<AdminUser>('/admin/session', { email, password })
    setSession({ status: 'signed_in', admin })
  }, [])

  const signOut = useCallback(async () => {
    // Optimistic on purpose. The point of the button on a shared machine is
    // that the screen is no longer showing the dashboard; waiting for a round
    // trip to hide it gets that backwards. The server call still happens, and
    // a failure would only mean the cookie outlives the screen — which is what
    // its own expiry is for.
    setSession({ status: 'signed_out' })
    await apiDelete('/admin/session').catch(() => undefined)
  }, [])

  /**
   * The session went away underneath a request — expired, or signed out in
   * another tab. Returns to the form rather than leaving a dead panel behind
   * with an error string in it.
   */
  const expired = useCallback(() => setSession({ status: 'signed_out' }), [])

  return { session, signIn, signOut, expired }
}

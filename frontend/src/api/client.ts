/**
 * Same-origin API access. In development Vite proxies `/api` and `/cable` to
 * Rails (vite.config.ts); in production nginx serves this bundle and proxies
 * the same two paths (§14.1). Neither case needs a configured host, which is
 * one fewer environment variable to get wrong in the cluster.
 */
export class ApiError extends Error {
  // Declared rather than a constructor parameter property: `erasableSyntaxOnly`
  // is on, so TypeScript-only syntax that emits runtime code is rejected.
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

export async function apiGet<T>(path: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(`/api/v1${path}`, {
    headers: { Accept: 'application/json' },
    signal,
  })

  if (!response.ok) {
    throw new ApiError(response.status, `GET ${path} failed with ${response.status}`)
  }

  return (await response.json()) as T
}

/**
 * POST with an optional station token (§13.3). The KDS is the only surface that
 * carries a bearer token — the board is public and admin uses a cookie session
 * — so the header is threaded through here rather than living in a global.
 */
export async function apiPost<T>(
  path: string,
  body: unknown = {},
  { token, signal }: { token?: string; signal?: AbortSignal } = {},
): Promise<T> {
  const response = await fetch(`/api/v1${path}`, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
    signal,
  })

  if (!response.ok) {
    const message = await response
      .json()
      .then((payload: { error?: string }) => payload.error)
      .catch(() => undefined)

    throw new ApiError(response.status, message ?? `POST ${path} failed with ${response.status}`)
  }

  return (await response.json()) as T
}

/**
 * DELETE, for signing out of the admin session (§13.4).
 *
 * No token argument: admin is the cookie surface, and the cookie rides on a
 * same-origin request without anything being threaded through.
 */
export async function apiDelete(path: string): Promise<void> {
  const response = await fetch(`/api/v1${path}`, {
    method: 'DELETE',
    headers: { Accept: 'application/json' },
  })

  if (!response.ok) {
    throw new ApiError(response.status, `DELETE ${path} failed with ${response.status}`)
  }
}

/** GET carrying a station token, for the KDS queue snapshot. */
export async function apiGetWithToken<T>(path: string, token: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(`/api/v1${path}`, {
    headers: { Accept: 'application/json', Authorization: `Bearer ${token}` },
    signal,
  })

  if (!response.ok) {
    throw new ApiError(response.status, `GET ${path} failed with ${response.status}`)
  }

  return (await response.json()) as T
}

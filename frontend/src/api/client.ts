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

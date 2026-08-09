import { renderHook, waitFor } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { blocksOrdering, useHealth, FAILURES_BEFORE_PAUSED, POLL_INTERVAL_MS } from './useHealth'
import { server } from '../test/server'

// Counted, because advancing the clock only *starts* a poll. Asserting right
// after `advanceTimersByTime` observes the state before the response has landed
// — which made "does not pause on a single failure" pass even when the code
// paused on the first one. A negative assertion has to know the thing it is
// denying actually happened.
let polls = 0

function healthy(accepting = true) {
  return http.get('/api/v1/health', () => {
    polls += 1
    return HttpResponse.json({ accepting_orders: accepting, store_name: 'Boba Gals' })
  })
}

function unreachable() {
  return http.get('/api/v1/health', () => {
    polls += 1
    return HttpResponse.error()
  })
}

/** Advances one interval and waits for that poll to have been answered. */
async function pollOnce() {
  const before = polls

  await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
  await waitFor(() => expect(polls).toBeGreaterThan(before))
  // One more turn for the state update the response triggers.
  await vi.advanceTimersByTimeAsync(0)
}

beforeEach(() => {
  polls = 0
  vi.useFakeTimers({ shouldAdvanceTime: true })
})

afterEach(() => {
  vi.useRealTimers()
})

describe('useHealth (§9.3, locked in §3)', () => {
  it('starts out checking rather than paused', () => {
    server.use(healthy())

    const { result } = renderHook(() => useHealth())

    // Rendering the refusal before the first response lands would flash
    // "Ordering is paused" on every boot.
    expect(result.current).toBe('checking')
  })

  it('goes live once the shop answers', async () => {
    server.use(healthy())

    const { result } = renderHook(() => useHealth())

    await waitFor(() => expect(result.current).toBe('live'))
  })

  // "Two consecutive failures" (§9.3). A single dropped request on shop wifi is
  // normal, and refusing to sell on every blip costs more than noticing an
  // outage ten seconds later.
  it('does not pause on a single failure', async () => {
    server.use(healthy())
    const { result } = renderHook(() => useHealth())
    await waitFor(() => expect(result.current).toBe('live'))

    server.use(unreachable())
    await pollOnce()

    expect(result.current).toBe('live')
  })

  it('pauses on the second consecutive failure', async () => {
    server.use(unreachable())

    const { result } = renderHook(() => useHealth())

    for (let i = 0; i < FAILURES_BEFORE_PAUSED; i++) await pollOnce()

    await waitFor(() => expect(result.current).toBe('unreachable'))
  })

  // The count is *consecutive*. Two failures either side of a success are two
  // blips, not an outage.
  it('forgets earlier failures after a success', async () => {
    server.use(unreachable())
    const { result } = renderHook(() => useHealth())
    await pollOnce()

    server.use(healthy())
    await pollOnce()
    await waitFor(() => expect(result.current).toBe('live'))

    server.use(unreachable())
    await pollOnce()

    expect(result.current).toBe('live')
  })

  // Asymmetric on purpose: two failures to stop, one success to start. Being
  // slow to sell again is a cost with no upside.
  it('recovers on the first success', async () => {
    server.use(unreachable())
    const { result } = renderHook(() => useHealth())
    for (let i = 0; i < FAILURES_BEFORE_PAUSED; i++) await pollOnce()
    await waitFor(() => expect(result.current).toBe('unreachable'))

    server.use(healthy())
    await pollOnce()

    await waitFor(() => expect(result.current).toBe('live'))
  })

  // `/health` is a *business* check, not a liveness one — it answers "is the
  // store taking orders" (health_controller.rb). `CreateOrder` would refuse the
  // order anyway, so letting a customer build a cart is the worse outcome.
  // A reachable shop that is not selling is a *different fact* from an
  // unreachable one, and the screen says so. Collapsing them tells a customer
  // the kiosk is broken when the owner simply closed ordering.
  it('reports not-accepting separately from unreachable', async () => {
    server.use(healthy(false))

    const { result } = renderHook(() => useHealth())

    await waitFor(() => expect(result.current).toBe('not_accepting'))
  })

  it('treats both as blocking ordering', () => {
    expect(blocksOrdering('unreachable')).toBe(true)
    expect(blocksOrdering('not_accepting')).toBe(true)
    expect(blocksOrdering('live')).toBe(false)
    // Never on first load, or the kiosk flashes a refusal on every boot.
    expect(blocksOrdering('checking')).toBe(false)
  })

  // The web flow is a phone, which shows its own connectivity and has no
  // attract screen to fall back to.
  // These two assert a poll does *not* happen, so they advance the clock
  // directly — `pollOnce` waits for a request that by definition never comes.
  it('does not poll at all when disabled', async () => {
    server.use(healthy())

    const { result } = renderHook(() => useHealth(false))
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS * 2)

    expect(polls).toBe(0)
    expect(result.current).toBe('checking')
  })

  it('stops polling once the screen is gone', async () => {
    server.use(healthy())
    const { unmount } = renderHook(() => useHealth())
    await waitFor(() => expect(polls).toBe(1))

    unmount()
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS * 2)

    expect(polls).toBe(1)
  })
})

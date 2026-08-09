import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { http, HttpResponse } from 'msw'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { KdsScreen } from './KdsScreen'
import { server } from '../test/server'
import type { KdsItem, QueueUpdate } from '../api/types'

// jsdom has no ActionCable server. What matters is that a broadcast reaches the
// screen, so the subscription is replaced with a handle the test can push through.
let broadcast: (update: QueueUpdate) => void = () => {}
// Captured and asserted on: KitchenChannel rejects a subscription whose
// store_id does not match the token (§13.3), and a mock that ignores the params
// cannot tell a correct subscription from one that will be refused. Passing the
// station id worked for station 1 of store 1 and no other station.
let subscribedWith: Record<string, unknown> | undefined

vi.mock('../api/cable', () => ({
  subscribe: ({
    onReceived,
    onConnected,
    params,
  }: {
    onReceived: (data: QueueUpdate) => void
    onConnected?: () => void
    params?: Record<string, unknown>
  }) => {
    broadcast = onReceived
    subscribedWith = params
    onConnected?.()
    return () => {}
  },
}))

function drink(overrides: Partial<KdsItem> = {}): KdsItem {
  return {
    id: 1, label: 'Classic Milk Tea, 50%, LESS ICE', status: 'queued', prep_seconds: 45,
    pickup_code: 'A1B2', position: 1, order_size: 1, remake: false,
    station_id: null, started_at: null, ...overrides,
  }
}

function queueUpdate(overrides: Partial<QueueUpdate> = {}): QueueUpdate {
  return { type: 'queue_update', in_progress: [], next_up: [], depth: 0, oldest_waiting_seconds: 0, ...overrides }
}

let posted: string[] = []

function serveKds(snapshot: QueueUpdate) {
  posted = []
  server.use(
    http.post('/api/v1/kds/session', () =>
      HttpResponse.json({
        token: 'tok', expires_in: 3600,
        barista: { id: 1, name: 'Mei' },
        station: { id: 2, name: 'Bar 2' },
        store: { id: 1, name: 'Boba Gals' },
      }),
    ),
    http.get('/api/v1/kds/queue', () => HttpResponse.json(snapshot)),
    http.post('/api/v1/kds/items/start', () => {
      posted.push('start')
      return HttpResponse.json(drink({ id: 9, status: 'in_progress' }))
    }),
    http.post('/api/v1/kds/items/:id/finish', ({ params }) => {
      posted.push(`finish:${params.id}`)
      return HttpResponse.json(drink({ id: Number(params.id), status: 'finished' }))
    }),
    http.post('/api/v1/kds/items/:id/fail', async ({ params, request }) => {
      const body = (await request.json()) as { reason?: string }
      posted.push(`fail:${params.id}:${body.reason}`)
      return HttpResponse.json(drink({ id: 99, status: 'queued', remake: true }))
    }),
    http.post('/api/v1/kds/items/:id/undo', ({ params }) => {
      posted.push(`undo:${params.id}`)
      return HttpResponse.json(drink({ id: Number(params.id), status: 'queued' }))
    }),
  )
}

async function signIn(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByLabelText('station'), '2')
  await user.type(screen.getByLabelText('pin'), '1234')
  await user.click(screen.getByRole('button', { name: /start shift/i }))
}

async function open(snapshot: QueueUpdate) {
  const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
  serveKds(snapshot)
  render(<KdsScreen />)
  await signIn(user)

  // Wait for the *queue snapshot*, not just for the session.
  //
  // The sign-out control renders the moment a session exists, which is before
  // `GET /kds/queue` resolves. Waiting on it left every example that then
  // queried synchronously for queue content racing the fetch — and on a loaded
  // CI runner the fetch lost, which is how "marks a remake" and "finishes a
  // drink in one tap" failed on a merge commit having passed on their own.
  //
  // The header renders "—" for the oldest wait until a snapshot has arrived, so
  // that is the signal. Deliberately not the sign-out button and deliberately
  // not a bare `waitFor` on some later assertion: this is the one condition
  // every example downstream actually depends on.
  await waitFor(() =>
    expect(screen.getByText('oldest').nextElementSibling).not.toHaveTextContent('—'),
  )

  return user
}

// The header's oldest-wait clock is driven by a real interval, so the examples
// that assert it advancing need control of time. `shouldAdvanceTime` keeps the
// fake clock moving with the real one, which is what lets MSW and userEvent
// carry on working normally around it.
/**
 * The header's oldest-wait value, in seconds.
 *
 * Read from the DOM and compared numerically rather than asserted as an exact
 * string: `shouldAdvanceTime` lets real time elapse alongside the fake clock,
 * so pinning an exact second would be a flake waiting for a slow CI box. What
 * the examples are about is the direction and the magnitude, not the tick.
 */
function oldestWaitSeconds(): number {
  const [ minutes, seconds ] = (screen.getByText('oldest').nextElementSibling?.textContent ?? '')
    .split(':')
    .map(Number)

  return minutes * 60 + seconds
}

beforeEach(() => {
  vi.useFakeTimers({ shouldAdvanceTime: true })
  broadcast = () => {}
  subscribedWith = undefined
  // The signed-in station now survives a reload, which means it survives from
  // one example into the next unless it is cleared here.
  sessionStorage.clear()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('KdsScreen', () => {
  describe('signing in (§13.3)', () => {
    it('shows the queue once a station and PIN are accepted' , async () => {
      await open(queueUpdate({ depth: 3 }))

      expect(screen.getByText('Bar 2', { exact: false })).toBeInTheDocument()
    })

    // Deliberately identical whether the station or the PIN was wrong, so the
    // message must not claim to know which.
    it('surfaces a rejected sign-in without saying which field was wrong', async () => {
      const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
      server.use(
        http.post('/api/v1/kds/session', () =>
          HttpResponse.json({ error: 'invalid station or PIN' }, { status: 401 }),
        ),
      )
      render(<KdsScreen />)
      await signIn(user)

      expect(await screen.findByRole('alert')).toHaveTextContent(/invalid station or pin/i)
    })
  })

  // "Show queue depth and the oldest waiting time in the header. Nothing else."
  // A KDS tablet gets refreshed — by a barista, by an OS update, by a browser
  // that reloads a backgrounded tab. Signing in again mid-rush is exactly the
  // wrong moment for it.
  describe('staying signed in (§13.3)', () => {
    it('is still signed in after a reload', async () => {
      await open(queueUpdate({ depth: 3 }))

      cleanup()
      serveKds(queueUpdate({ depth: 3 }))
      render(<KdsScreen />)

      expect(await screen.findByRole('button', { name: /sign out/i })).toBeInTheDocument()
      expect(screen.queryByLabelText('station')).not.toBeInTheDocument()
    })

    // A shared tablet must not hand the next barista the last one's shift.
    it('signing out ends it for good', async () => {
      const user = await open(queueUpdate({ depth: 3 }))

      await user.click(screen.getByRole('button', { name: /sign out/i }))
      cleanup()
      render(<KdsScreen />)

      expect(await screen.findByLabelText('station')).toBeInTheDocument()
    })

    // The token carries a 12-hour expiry (§13.3). A restored one can outlive
    // it, and a screen showing a stale queue behind a dead token is worse than
    // a sign-in prompt — every tap would 401.
    it('falls back to sign-in when the restored token is rejected', async () => {
      await open(queueUpdate({ depth: 3 }))

      cleanup()
      serveKds(queueUpdate({ depth: 3 }))
      server.use(
        http.get('/api/v1/kds/queue', () =>
          HttpResponse.json({ error: 'invalid token' }, { status: 401 }),
        ),
      )
      render(<KdsScreen />)

      expect(await screen.findByLabelText('station')).toBeInTheDocument()
    })

    it('does not choke on a corrupted stored session', async () => {
      sessionStorage.setItem('boba_gals.kds_session', 'not json')
      serveKds(queueUpdate({ depth: 1 }))

      render(<KdsScreen />)

      expect(await screen.findByLabelText('station')).toBeInTheDocument()
    })

    // Valid JSON of the wrong shape gets past the parse and would otherwise be
    // handed to the screen as a session — `session.station.name` in the header
    // is enough to take the whole KDS down, on the screen the shop runs on.
    it('rejects a stored value that parses but is not a session', async () => {
      sessionStorage.setItem('boba_gals.kds_session', JSON.stringify({ token: 'tok' }))
      serveKds(queueUpdate({ depth: 1 }))

      render(<KdsScreen />)

      expect(await screen.findByLabelText('station')).toBeInTheDocument()
    })
  })

  describe('the header (§9.4)', () => {
    it('shows queue depth and the oldest wait', async () => {
      await open(queueUpdate({ depth: 7, oldest_waiting_seconds: 440 }))

      expect(screen.getByText('7')).toBeInTheDocument()
      expect(screen.getByText('7:20')).toBeInTheDocument()
    })

    it('flags an oldest wait that has got out of hand' , async () => {
      await open(queueUpdate({ depth: 2, oldest_waiting_seconds: 900 }))

      expect(screen.getByText('15:00').className).toContain('orange')
    })

    // A quiet store broadcasts only on §7.2's 30s idle tick, so a header frozen
    // at whatever the last snapshot said is how a drink gets forgotten.
    it('counts the oldest wait up between snapshots', async () => {
      await open(queueUpdate({ depth: 2, oldest_waiting_seconds: 100 }))
      const started = oldestWaitSeconds()
      expect(started).toBeGreaterThanOrEqual(100)

      act(() => vi.advanceTimersByTime(5000))

      // `- 1` because the 1-second interval keeps its own phase: its last fire
      // inside the advanced window can be up to a tick short of the end, so the
      // display trails by up to a second. That is the real behaviour, not slack
      // in the test — a barista sees the same lag.
      expect(oldestWaitSeconds()).toBeGreaterThanOrEqual(started + 4)
      expect(oldestWaitSeconds()).toBeLessThan(started + 10)
    })

    // An empty queue has no oldest drink; ticking up from nothing would invent
    // a wait, and the orange threshold would eventually trip on it.
    it('does not invent a wait when nothing is queued', async () => {
      await open(queueUpdate({ depth: 0, oldest_waiting_seconds: 0 }))

      act(() => vi.advanceTimersByTime(30_000))

      expect(oldestWaitSeconds()).toBe(0)
    })

    // The server is the authority. A client that kept adding to its own total
    // would drift further from the truth the longer the tab stayed open.
    it('restarts from the newest snapshot rather than accumulating', async () => {
      await open(queueUpdate({ depth: 2, oldest_waiting_seconds: 100 }))
      act(() => vi.advanceTimersByTime(5000))

      act(() => broadcast(queueUpdate({ depth: 2, oldest_waiting_seconds: 20 })))
      act(() => vi.advanceTimersByTime(2000))

      // Back near the server's 20, not the ~105 it had climbed to. The lower
      // bound is 20 rather than 22 because the display lags by up to one tick:
      // the interval keeps its own phase and does not restart with the
      // snapshot.
      //
      // The upper bound is what makes this an assertion. A client that never
      // reset its origin would show 20 + the 7s elapsed since mount, so
      // anything at or above 25 means the snapshot's arrival was ignored.
      expect(oldestWaitSeconds()).toBeGreaterThanOrEqual(20)
      expect(oldestWaitSeconds()).toBeLessThan(25)
    })
  })

  describe('a drink card (§9.4)', () => {
    it('breaks the label into a name and bold option tokens', async () => {
      await open(queueUpdate({ in_progress: [ drink({ status: 'in_progress' }) ] }))

      expect(screen.getByText('Classic Milk Tea')).toBeInTheDocument()
      expect(screen.getByText('50%')).toBeInTheDocument()
      expect(screen.getByText('LESS ICE')).toBeInTheDocument()
    })

    // How a barista knows the drink in their hand belongs to a larger order the
    // scheduler is interleaving, rather than one they are making out of order.
    it('shows the position within a multi-drink order', async () => {
      await open(queueUpdate({ in_progress: [ drink({ status: 'in_progress', position: 2, order_size: 5 }) ] }))

      expect(screen.getByText('2 of 5')).toBeInTheDocument()
    })

    it('does not clutter a single-drink order with a position', async () => {
      await open(queueUpdate({ in_progress: [ drink({ status: 'in_progress', position: 1, order_size: 1 }) ] }))

      expect(screen.queryByText('1 of 1')).not.toBeInTheDocument()
    })

    // "Remakes carry a distinct persistent marker" — persistent, because the
    // barista who needs it may not be the one who was there when it was made.
    it('marks a remake', async () => {
      await open(queueUpdate({ in_progress: [ drink({ status: 'in_progress', remake: true }) ] }))

      expect(screen.getByText(/remake/i)).toBeInTheDocument()
    })
  })

  describe('working the queue (§9.4)', () => {
    // `start` takes no id — the server picks, which is what lets the scheduler
    // decide rather than the barista.
    it('asks the server for the next drink rather than naming one', async () => {
      const user = await open(queueUpdate({ depth: 4 }))

      await user.click(screen.getByRole('button', { name: /start next drink/i }))

      await waitFor(() => expect(posted).toEqual([ 'start' ]))
    })

    it('offers nothing to start when the queue is empty', async () => {
      await open(queueUpdate({ depth: 0 }))

      expect(screen.getByRole('button', { name: /nothing waiting/i })).toBeDisabled()
    })

    // One tap to finish. No confirmation dialog (§9.4).
    it('finishes a drink in one tap', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))

      await user.click(screen.getByRole('button', { name: 'Done' }))

      await waitFor(() => expect(posted).toEqual([ 'finish:42' ]))
    })

    // The station id and the store id are different numbers for every station
    // but the first, and sending the wrong one leaves the screen at
    // "connecting" with no error — the subscription is simply refused.
    it('subscribes with the store id, not the station id', async () => {
      await open(queueUpdate({ depth: 1 }))

      expect(subscribedWith).toMatchObject({ store_id: 1, token: 'tok' })
      expect(subscribedWith?.store_id).not.toBe(2)
    })

    it('renders a broadcast snapshot without reconciling against the old one', async () => {
      await open(queueUpdate({ depth: 1 }))

      broadcast(queueUpdate({ depth: 9, in_progress: [ drink({ id: 5, status: 'in_progress', label: 'Taro Slush' }) ] }))

      expect(await screen.findByText('Taro Slush')).toBeInTheDocument()
      expect(screen.getByText('9')).toBeInTheDocument()
    })
  })

  // "Always render a Next up section (3 items) so a barista can pre-stage cups
  // and toppings. This is where real throughput comes from." Always — so it
  // never moves under a barista's hand.
  describe('next up (§9.4)', () => {
    it('lists what is coming', async () => {
      await open(queueUpdate({
        depth: 2,
        next_up: [ drink({ id: 2, label: 'Taro Slush' }), drink({ id: 3, label: 'Thai Tea' }) ],
      }))

      const section = screen.getByRole('region', { name: /next up/i })
      expect(section).toHaveTextContent('Taro Slush')
      expect(section).toHaveTextContent('Thai Tea')
    })

    it('is rendered even when there is nothing coming' , async () => {
      await open(queueUpdate({ depth: 0 }))

      expect(screen.getByRole('region', { name: /next up/i })).toBeInTheDocument()
    })
  })

  // §9.4: "Fail/remake requires a reason tap (spill, wrong order, quality) —
  // one screen, four large buttons."
  describe('remaking a drink that went wrong (§5.2, §9.4)', () => {
    async function openReasons(user: ReturnType<typeof userEvent.setup>) {
      await user.click(screen.getByRole('button', { name: /report a problem/i }))
    }

    it('asks why before doing anything', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))

      await openReasons(user)

      expect(screen.getByRole('dialog', { name: /why is this drink being remade/i })).toBeInTheDocument()
      expect(posted).toEqual([])
    })

    it('offers §9.4\'s three reasons and a way out', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))

      await openReasons(user)

      expect(screen.getByRole('button', { name: /spilled/i })).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /wrong drink/i })).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /not right/i })).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument()
    })

    it('sends the reason the barista tapped', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))
      await openReasons(user)

      await user.click(screen.getByRole('button', { name: /wrong drink/i }))

      await waitFor(() => expect(posted).toEqual([ 'fail:42:wrong_order' ]))
    })

    it('backs out without touching the drink', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))
      await openReasons(user)

      await user.click(screen.getByRole('button', { name: /cancel/i }))

      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
      expect(posted).toEqual([])
    })

    // A remake records that a real drink was really made wrong (§5.2). Undoing
    // it would delete the evidence and leave the customer with no drink — a
    // barista who taps it by accident fails the remake in turn.
    it('offers no undo, unlike every other action', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))
      await openReasons(user)

      await user.click(screen.getByRole('button', { name: /spilled/i }))

      await waitFor(() => expect(posted).toHaveLength(1))
      expect(screen.queryByRole('button', { name: /undo/i })).not.toBeInTheDocument()
    })
  })

  // The only protection against a mistap, there being no confirmation dialog.
  describe('undo (§9.4, §5.2)', () => {
    it('offers to undo the last action', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))

      await user.click(screen.getByRole('button', { name: 'Done' }))

      expect(await screen.findByRole('button', { name: /undo/i })).toBeInTheDocument()
      expect(screen.getByText(/finished/i)).toBeInTheDocument()
    })

    it('sends the undo for the drink that was acted on', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))
      await user.click(screen.getByRole('button', { name: 'Done' }))
      await user.click(await screen.findByRole('button', { name: /undo/i }))

      await waitFor(() => expect(posted).toEqual([ 'finish:42', 'undo:42' ]))
    })

    it('clears the affordance once used', async () => {
      const user = await open(queueUpdate({ in_progress: [ drink({ id: 42, status: 'in_progress' }) ] }))
      await user.click(screen.getByRole('button', { name: 'Done' }))
      await user.click(await screen.findByRole('button', { name: /undo/i }))

      await waitFor(() => expect(screen.queryByRole('button', { name: /undo/i })).not.toBeInTheDocument())
    })

    it('shows nothing to undo before anything has been done', async () => {
      await open(queueUpdate({ in_progress: [ drink({ status: 'in_progress' }) ] }))

      expect(screen.queryByRole('button', { name: /undo/i })).not.toBeInTheDocument()
    })
  })

  it('surfaces a failed action rather than silently doing nothing', async () => {
    const user = await open(queueUpdate({ depth: 1 }))
    server.use(
      http.post('/api/v1/kds/items/start', () =>
        HttpResponse.json({ error: 'nothing queued' }, { status: 404 }),
      ),
    )

    await user.click(screen.getByRole('button', { name: /start next drink/i }))

    expect(await screen.findByRole('alert')).toHaveTextContent(/nothing queued/i)
  })
})

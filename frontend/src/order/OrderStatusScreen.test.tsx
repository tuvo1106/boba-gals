import { render, screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { OrderStatusScreen } from './OrderStatusScreen'
import { server } from '../test/server'
import type { OrderUpdate, PlacedOrder } from '../api/types'

// jsdom has no ActionCable server. What matters is that a broadcast reaches the
// screen, so the subscription is replaced with a handle the test can push
// through — and the params are captured, because OrderChannel rejects a
// subscription it cannot resolve to an order and a mock that ignores them
// cannot tell a correct subscription from one that will be refused.
let broadcast: (update: OrderUpdate) => void = () => {}
let subscribedWith: Record<string, unknown> | undefined

vi.mock('../api/cable', () => ({
  subscribe: ({
    onReceived,
    params,
  }: {
    onReceived: (data: OrderUpdate) => void
    params?: Record<string, unknown>
  }) => {
    broadcast = onReceived
    subscribedWith = params
    return () => {}
  },
}))

function order(overrides: Partial<PlacedOrder> = {}): PlacedOrder {
  return {
    pickup_code: 'R55Z', status: 'placed', source: 'web',
    customer_first_name: 'Tu', placed_at: '2026-08-09T02:01:22Z',
    promised_at: null, ready_at: null, total_cents: 1175, quoted_wait_seconds: 240,
    items: [
      { id: 1, label: 'Classic Milk Tea, 50%', status: 'queued', prep_seconds: 60, sequence: 1, remake: false },
      { id: 2, label: 'Taro Slush', status: 'queued', prep_seconds: 45, sequence: 2, remake: false },
    ],
    ...overrides,
  }
}

function update(overrides: Partial<OrderUpdate> = {}): OrderUpdate {
  return {
    type: 'order_update', pickup_code: 'R55Z', status: 'in_progress', eta_seconds: 180,
    items: [
      { id: 1, label: 'Classic Milk Tea, 50%', status: 'in_progress' },
      { id: 2, label: 'Taro Slush', status: 'queued' },
    ],
    ...overrides,
  }
}

function serve(body: PlacedOrder = order()) {
  server.use(http.get('/api/v1/orders/:code', () => HttpResponse.json(body)))
}

beforeEach(() => {
  broadcast = () => {}
  subscribedWith = undefined
})

describe('OrderStatusScreen (§9.2, §9.3)', () => {
  it('leads with the pickup code, which is what the counter asks for', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)

    expect(within(await screen.findByRole('region', { name: /pickup code/i })).getByText('R55Z'))
      .toBeInTheDocument()
  })

  it('lists every drink in the order', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)

    expect(await screen.findByText('Classic Milk Tea, 50%')).toBeInTheDocument()
    expect(screen.getByText('Taro Slush')).toBeInTheDocument()
  })

  // A range rather than a point: the estimate genuinely moves, because §6.1
  // shares capacity with orders arriving behind this one.
  it('quotes the wait as a range', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)

    expect(await screen.findByText('4–6 min')).toBeInTheDocument()
  })

  // The one number on the screen that cannot go backwards, and the reason a
  // moving estimate beside it is tolerable.
  it('leads with how many drinks are made', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)

    expect(await screen.findByText('0 of 2 made')).toBeInTheDocument()
  })

  it('counts a drink as made as soon as the kitchen says so', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)
    await screen.findByText('0 of 2 made')

    broadcast(update({
      status: 'partially_ready',
      items: [
        { id: 1, label: 'Classic Milk Tea, 50%', status: 'finished' },
        { id: 2, label: 'Taro Slush', status: 'in_progress' },
      ],
    }))

    expect(await screen.findByText('1 of 2 made')).toBeInTheDocument()
  })

  // The code is the whole credential (§13.1) — there is no token, and
  // deliberately no account to sign in to (§9.3 is guest-only in v1).
  it('subscribes with the pickup code', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)

    await screen.findByText('Classic Milk Tea, 50%')
    expect(subscribedWith).toEqual({ pickup_code: 'R55Z' })
  })

  // §6 interleaves one order's drinks with everyone else's, so an order really
  // is part-done. One progress bar would sit still for eight minutes and jump.
  it('tracks each drink separately as the kitchen works', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)
    await screen.findByText('Classic Milk Tea, 50%')

    broadcast(update({
      status: 'partially_ready',
      items: [
        { id: 1, label: 'Classic Milk Tea, 50%', status: 'finished' },
        { id: 2, label: 'Taro Slush', status: 'in_progress' },
      ],
    }))

    expect(await screen.findByText('done')).toBeInTheDocument()
    expect(screen.getByText('making')).toBeInTheDocument()
  })

  it('announces the order as ready', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)
    await screen.findByText('Classic Milk Tea, 50%')

    broadcast(update({
      status: 'ready',
      eta_seconds: 0,
      items: [
        { id: 1, label: 'Classic Milk Tea, 50%', status: 'finished' },
        { id: 2, label: 'Taro Slush', status: 'finished' },
      ],
    }))

    expect(await screen.findByText(/come and collect it/i)).toBeInTheDocument()
  })

  // A countdown next to "Ready" is worse than no countdown, and so is a
  // progress line that has nothing left to report.
  it('drops the estimate and the progress line once the order is ready', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)
    await screen.findByText('4–6 min')

    broadcast(update({
      status: 'ready',
      eta_seconds: 0,
      items: [
        { id: 1, label: 'Classic Milk Tea, 50%', status: 'finished' },
        { id: 2, label: 'Taro Slush', status: 'finished' },
      ],
    }))

    expect(await screen.findByText(/come and collect it/i)).toBeInTheDocument()
    expect(screen.queryByText(/min$/)).not.toBeInTheDocument()
    expect(screen.queryByText(/made$/)).not.toBeInTheDocument()
  })

  // Whole snapshots, never deltas (§9.2): a client that misses a message
  // renders the next one correctly rather than reconciling.
  it('renders a broadcast without reconciling against what it had', async () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)
    await screen.findByText('Taro Slush')

    broadcast(update({
      items: [ { id: 7, label: 'Thai Tea', status: 'in_progress' } ],
    }))

    expect(await screen.findByText('Thai Tea')).toBeInTheDocument()
    expect(screen.queryByText('Taro Slush')).not.toBeInTheDocument()
  })

  // A 404 is an answer — this code is not a live order here today, and asking
  // again will not change it. That is why it is the *only* failure that
  // surfaces; everything else is retried. See the two tests below.
  it('says so when the code matches no order', async () => {
    server.use(
      http.get('/api/v1/orders/:code', () => HttpResponse.json({ error: 'not found' }, { status: 404 })),
    )
    render(<OrderStatusScreen pickupCode="ZZZZ" mode="web" />)

    expect(await screen.findByRole('alert')).toHaveTextContent(/could not find that order/i)
  })

  // The customer just placed this order and is holding the pickup code. A blip
  // on shop wifi used to replace the whole screen — code and all — with "We
  // could not find that order.", because every failure was read as "no such
  // order". The code is the only thing they have to show at the counter (§13.1).
  it('keeps the order on screen when the read fails', async () => {
    server.use(http.get('/api/v1/orders/:code', () => HttpResponse.error()))
    render(<OrderStatusScreen pickupCode="R55Z" seed={order()} mode="web" />)

    // Long enough for the rejection to land and a re-render to follow it.
    await waitFor(() => expect(screen.getByText('R55Z')).toBeInTheDocument())
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.getByText('Classic Milk Tea, 50%')).toBeInTheDocument()
  })

  // Transient failures are retried rather than surfaced, so the screen comes
  // back on its own once the API does — the same reasoning as the board (§9.4).
  it('retries a failed read and recovers', async () => {
    let attempts = 0
    server.use(
      http.get('/api/v1/orders/:code', () => {
        attempts += 1
        if (attempts === 1) return HttpResponse.error()

        return HttpResponse.json(order())
      }),
    )
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)

    expect(await screen.findByText('Classic Milk Tea, 50%', undefined, { timeout: 5_000 }))
      .toBeInTheDocument()
    expect(attempts).toBeGreaterThan(1)
  })

  // Reached by placing the order, the screen already has it — a round trip and
  // a blank first frame for data it was just handed would be a regression a
  // customer sees.
  it('renders immediately from the order it was seeded with', () => {
    serve()
    render(<OrderStatusScreen pickupCode="R55Z" seed={order()} mode="web" />)

    expect(screen.getByText('Classic Milk Tea, 50%')).toBeInTheDocument()
  })

  // A broadcast that has already arrived is fresher than the REST read, which
  // must not roll it back.
  it('does not let the initial fetch overwrite a broadcast that beat it', async () => {
    server.use(
      http.get('/api/v1/orders/:code', async () => {
        await new Promise((resolve) => setTimeout(resolve, 50))
        return HttpResponse.json(order())
      }),
    )
    render(<OrderStatusScreen pickupCode="R55Z" mode="web" />)

    broadcast(update({ items: [ { id: 1, label: 'Classic Milk Tea, 50%', status: 'in_progress' } ] }))
    expect(await screen.findByText('making')).toBeInTheDocument()

    // Well past the fetch settling.
    await new Promise((resolve) => setTimeout(resolve, 120))
    expect(screen.getByText('making')).toBeInTheDocument()
  })
})

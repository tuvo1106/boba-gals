import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { DashboardScreen } from './DashboardScreen'
import { server } from '../test/server'
import type { SimulationRun } from '../api/types'

/** Every request the screen makes, so a test can assert what it asked for. */
let requests: Record<string, unknown>[] = []

/**
 * `Omit` rather than intersecting `Partial<SimulationRun>` with a partial
 * `metrics`: intersecting leaves `metrics` as `Metrics & Partial<Metrics>`,
 * which is still fully required, so no partial override is assignable.
 */
type RunOverrides = Omit<Partial<SimulationRun>, 'metrics'> & {
  metrics?: Partial<SimulationRun['metrics']>
}

function serveRun({ metrics: metricOverrides = {}, ...overrides }: RunOverrides = {}) {
  requests = []
  server.use(
    http.post('/api/v1/admin/simulations', async ({ request }) => {
      const body = (await request.json()) as Record<string, unknown>
      requests.push(body)

      const from = Number(body.window_from ?? 0)
      const span = Number(body.window_seconds ?? 1200)

      return HttpResponse.json({
        seed: Number(body.seed ?? 7),
        stations: 2,
        window: { from, to: from + span },
        timeline: [],
        order_spans: [
          // Order 1 arrives at open. Order 3 is an order-ahead (§10.3) and is
          // made hours later, which is why id order is not ribbon order.
          [ 1, 60, 120, 1 ],
          [ 11, 900, 980, 2 ],
          [ 3, 20000, 20400, 8 ],
        ],
        metrics: {
          orders: 385, drinks: 757,
          wait_seconds: { p50: 60, p90: 120, p99: 300 },
          by_size_class: {
            '1-2': { orders: 300, p90_meaningful: true, p50: 60, p90: 129.1, p99: 200 },
            '3-6': { orders: 60, p90_meaningful: true, p50: 100, p90: 200, p99: 400 },
            '7+': { orders: 25, p90_meaningful: true, p50: 300, p90: 494.8, p99: 900 },
          },
          wait_by_drink_cost: {
            cheap: { orders: 200, p90: 100 }, dear: { orders: 40, p90: 127 }, ratio: 1.27,
            comparable: true,
          },
          station_utilisation: 0.364,
          cohesion_spread_p90: 40,
          max_queue_depth: 12,
          quality_breach_rate: 0.132,
          quality_breach_rate_multi: 0.263,
          reneged: 0,
          remakes: 19,
          ...metricOverrides,
        },
        ...overrides,
      } as SimulationRun)
    }),
  )
}

async function renderRun() {
  serveRun()
  render(<DashboardScreen />)
  await screen.findByText(/small-order p90/i)
}

/** Drives the real control rather than relying on implicit form submission,
 *  which jsdom does not implement. */
async function findOrder(user: ReturnType<typeof userEvent.setup>, id: string) {
  await user.clear(screen.getByLabelText('find order'))
  await user.type(screen.getByLabelText('find order'), id)
  await user.click(screen.getByRole('button', { name: 'go' }))
}

describe('DashboardScreen', () => {
  it('opens on the lunch peak rather than at open, where nothing is contended', async () => {
    await renderRun()

    expect(requests[0].window_from).toBe(7200)
    expect(screen.getByText('12:00–12:20')).toBeInTheDocument()
  })

  // §10.6: "every run must display its seed" — a result nobody can replay is an
  // anecdote.
  it('shows the seed the run used', async () => {
    await renderRun()

    expect(screen.getByLabelText('seed')).toHaveValue(7)
  })

  // Every figure has to say which direction is good, or an operator reading
  // "0.364" has no way to know whether to add a station.
  describe('metric glosses', () => {
    it('explains what each figure measures', async () => {
      await renderRun()

      expect(screen.getByText(/decides staffing/i)).toBeInTheDocument()
      expect(screen.getByText(/a 95s drink takes 95s under any policy/i)).toBeInTheDocument()
    })

    // §10.4's threshold: past ~85% queues grow nonlinearly.
    it('reads utilisation as healthy well below the nonlinear knee', async () => {
      await renderRun()

      expect(screen.getByText('36.4%').className).toContain('emerald')
    })

    it('reads utilisation as critical past 85%', async () => {
      serveRun({ metrics: { station_utilisation: 0.91 } })
      render(<DashboardScreen />)

      expect((await screen.findByText('91.0%')).className).toContain('rose')
    })
  })

  describe('finding an order', () => {
    it('scrubs the window to where the order was actually made', async () => {
      const user = userEvent.setup()
      await renderRun()

      await findOrder(user, '1')

      // Order 1 ran 60–120s: a 60s order centred in a 1200s window opens at 0,
      // clamped from the negative start the arithmetic would otherwise give.
      await waitFor(() => expect(requests).toHaveLength(2))
      expect(requests[1].window_from).toBe(0)
    })

    // Ids run in arrival order but dispatch order is not id order, so "show me
    // order 3" cannot be answered by arithmetic on the id (§10.3).
    it('follows an order-ahead order to its dispatch, not its arrival', async () => {
      const user = userEvent.setup()
      await renderRun()

      await findOrder(user, '3')

      await waitFor(() => expect(requests).toHaveLength(2))
      expect(Number(requests[1].window_from)).toBeGreaterThan(19000)
    })

    it('says so when the order was never made, rather than scrubbing nowhere', async () => {
      const user = userEvent.setup()
      await renderRun()

      await findOrder(user, '999')

      expect(await screen.findByRole('alert')).toHaveTextContent(/never made/i)
      expect(requests).toHaveLength(1)
    })

    it('offers to clear a pin only once something is pinned', async () => {
      const user = userEvent.setup()
      await renderRun()

      expect(screen.queryByRole('button', { name: 'clear' })).not.toBeInTheDocument()

      await findOrder(user, '1')
      await user.click(await screen.findByRole('button', { name: 'clear' }))

      expect(screen.queryByRole('button', { name: 'clear' })).not.toBeInTheDocument()
    })
  })

  // A p90 over five observations is the maximum, not a percentile — and it sat
  // on screen next to one computed from 300 orders.
  describe('when a figure has too few samples to mean anything', () => {
    it('says the 7+ figure is one order rather than a percentile', async () => {
      serveRun({
        metrics: {
          by_size_class: {
            '1-2': { orders: 300, p90_meaningful: true, p50: 60, p90: 129.1, p99: 200 },
            '3-6': { orders: 60, p90_meaningful: true, p50: 100, p90: 200, p99: 400 },
            '7+': { orders: 5, p90_meaningful: false, p50: 300, p90: 4659, p99: 4659 },
          },
        },
      })
      render(<DashboardScreen />)

      expect(await screen.findByText(/only 5 catering orders/i)).toBeInTheDocument()
      expect(screen.getByText(/slowest one rather than a percentile/i)).toBeInTheDocument()
    })

    it('trusts the figure once there are enough of them', async () => {
      await renderRun()

      expect(screen.getByText(/over 25 of them/i)).toBeInTheDocument()
    })

    // The headline number had no guard at all, which is what let the 7+ figure
    // ship as a percentile over five orders.
    it('guards the headline small-order figure too', async () => {
      serveRun({
        metrics: {
          by_size_class: {
            '1-2': { orders: 4, p90_meaningful: false, p50: 60, p90: 129.1, p99: 200 },
            '3-6': { orders: 60, p90_meaningful: true, p50: 100, p90: 200, p99: 400 },
            '7+': { orders: 25, p90_meaningful: true, p50: 300, p90: 494.8, p99: 900 },
          },
        },
      })
      render(<DashboardScreen />)

      expect(await screen.findByText(/only 4 small orders/i)).toBeInTheDocument()
    })

    // Zero is not a perfect score. Rendering it green was the same bug as the
    // 7+ percentile, reintroduced by the metric added to expose that one.
    it('shows no penalty rather than a flawless one when nothing is comparable', async () => {
      serveRun({
        metrics: {
          wait_by_drink_cost: { cheap: { orders: 0, p90: 0 }, dear: { orders: 0, p90: 0 }, ratio: 0, comparable: false },
        },
      })
      render(<DashboardScreen />)

      expect(await screen.findByText('—')).toBeInTheDocument()
      expect(screen.getByText(/not enough of one kind to compare/i)).toBeInTheDocument()
      expect(screen.queryByText('0.00×')).not.toBeInTheDocument()
    })
  })

  // Below saturation every policy dispatches almost the same order, so the
  // dashboard must not invite a comparison it cannot support.
  describe('when the shop is too quiet to compare policies', () => {
    it('warns at low utilisation', async () => {
      serveRun({ metrics: { station_utilisation: 0.34 } })
      render(<DashboardScreen />)

      expect(await screen.findByText(/within noise/i)).toBeInTheDocument()
    })

    it('stays quiet once there is a queue to schedule', async () => {
      serveRun({ metrics: { station_utilisation: 0.8 } })
      render(<DashboardScreen />)
      await screen.findByText(/small-order p90/i)

      expect(screen.queryByText(/within noise/i)).not.toBeInTheDocument()
    })
  })

  it('surfaces a signed-out admin as something actionable', async () => {
    requests = []
    server.use(http.post('/api/v1/admin/simulations', () => new HttpResponse(null, { status: 401 })))
    render(<DashboardScreen />)

    expect(await screen.findByRole('alert')).toHaveTextContent(/sign in as admin/i)
  })
})

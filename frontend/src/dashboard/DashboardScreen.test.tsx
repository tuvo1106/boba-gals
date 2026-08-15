import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { StrictMode } from 'react'
import { DashboardScreen } from './DashboardScreen'
import { server } from '../test/server'
import type { SchedulerConfig, SimulationRun } from '../api/types'

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

/**
 * An already-signed-in admin (§13.4). Every example below the gate needs this,
 * because the dashboard asks the server who it is talking to before it renders
 * anything — the cookie is HttpOnly, so there is nothing else to ask.
 */
function serveSignedIn() {
  server.use(
    http.get('/api/v1/admin/session', () => HttpResponse.json({ email: 'admin@bobagals.test' })),
  )
  // Every render fetches this on mount for §10.6's "Apply to store" — a
  // default here keeps every other describe block's tests from having to
  // know that, the same way they don't have to mock /simulations by hand.
  serveSchedulerConfig()
}

function defaultSchedulerConfig(overrides: Partial<SchedulerConfig> = {}): SchedulerConfig {
  return {
    policy: 'drr', quantum: 60, aging_enabled: true, aging_rate: 0.15,
    cohesion_enabled: false, cohesion_boost: 1.0, remake_multiplier: 4.0,
    promise_buffer: 120, quality_limit_seconds: 300, eta_safety_factor: 1.15,
    ...overrides,
  }
}

function serveSchedulerConfig(overrides: Partial<SchedulerConfig> = {}) {
  server.use(
    http.get('/api/v1/admin/scheduler_config', () => HttpResponse.json({
      store_id: 1,
      scheduler_config: defaultSchedulerConfig(overrides),
      editable: Object.keys(defaultSchedulerConfig()),
    })),
  )
}

/**
 * The run a request would produce. Split out of `serveRun` so a test that needs
 * its own handler — to control *when* a response lands, say — can still return
 * a realistic run rather than reinventing thirty fields of metrics.
 */
function runBody(
  body: Record<string, unknown>,
  { metrics: metricOverrides = {}, ...overrides }: RunOverrides = {},
): SimulationRun {
  const from = Number(body.window_from ?? 0)
  const span = Number(body.window_seconds ?? 1200)

  return {
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
      eta_accuracy: { orders: 385, capped: 0, measurable: true, p50_abs: 14.5, p90_abs: 44.2, bias: 2.4 },
      quality_breach_rate: 0.132,
      quality_breach_rate_multi: 0.263,
      reneged: 0,
      remakes: 19,
      ...metricOverrides,
    },
    ...overrides,
  } as SimulationRun
}

function serveRun(overrides: RunOverrides = {}) {
  requests = []
  serveSignedIn()
  server.use(
    http.post('/api/v1/admin/simulations', async ({ request }) => {
      const body = (await request.json()) as Record<string, unknown>
      requests.push(body)

      return HttpResponse.json(runBody(body, overrides))
    }),
  )
}

async function renderRun() {
  serveRun()
  render(<DashboardScreen />)
  await screen.findByText(/small-order p90/i)
}

/** Glosses are opt-in — permanently-on prose made the panel a wall of text. */
async function explain(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: '?' }))
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
  // Every control here starts a run, and a run is a whole simulated day the
  // server computes from scratch — §10.5 puts the endpoint behind the admin
  // session for exactly that reason.
  describe('what starts a run', () => {
    it('does not re-run while the window is being dragged', async () => {
      await renderRun()
      const before = requests.length

      const slider = screen.getByLabelText('window start')
      // A drag is a stream of change events, one per `step`. Six is a nudge;
      // crossing the day is some six hundred.
      for (const value of [ 7260, 7320, 7380, 7440, 7500, 7560 ]) {
        fireEvent.change(slider, { target: { value: String(value) } })
      }

      expect(requests).toHaveLength(before)
      // The window still tracks the drag — this is a preview, not a freeze.
      expect(screen.getByText('12:06–12:26')).toBeInTheDocument()

      fireEvent.mouseUp(slider)

      await waitFor(() => expect(requests).toHaveLength(before + 1))
      expect(requests[requests.length - 1].window_from).toBe(7560)
    })

    // Runs take wildly different times — a policy that dispatches badly queues
    // more work — so the operator's *second* click routinely resolves first.
    // Without sequencing the chart ends up showing the run they abandoned, and
    // labelled with the policy they switched to, which is the worst of both:
    // a wrong answer wearing the right label. §10.6 exists to make these
    // comparisons trustworthy.
    it('ignores a run that was superseded before it landed', async () => {
      const user = userEvent.setup()
      serveSignedIn()
      requests = []

      let seen = 0
      server.use(
        http.post('/api/v1/admin/simulations', async ({ request }) => {
          const body = (await request.json()) as Record<string, unknown>
          requests.push(body)
          seen += 1
          const mine = seen

          // Run 1 is the mount. Run 2 is the abandoned one and is made slow, so
          // run 3 — the one the operator is actually waiting for — answers
          // first and run 2 arrives afterwards trying to claim the panel.
          if (mine === 2) await new Promise((resolve) => setTimeout(resolve, 80))

          return HttpResponse.json(runBody(body, {
            metrics: {
              by_size_class: {
                '1-2': { orders: 300, p90_meaningful: true, p50: 60, p90: mine === 2 ? 999 : 111, p99: 200 },
                '3-6': { orders: 60, p90_meaningful: true, p50: 100, p90: 200, p99: 400 },
                '7+': { orders: 25, p90_meaningful: true, p50: 300, p90: 494.8, p99: 900 },
              },
            },
          }))
        }),
      )

      render(<DashboardScreen />)
      await screen.findByText(/small-order p90/i)

      await user.click(screen.getByRole('button', { name: 'fifo' }))
      await user.click(screen.getByRole('button', { name: 'sjf' }))

      await waitFor(() => expect(requests).toHaveLength(3))
      // `getAllBy`: the headline figure also appears in the ghost of the
      // previous run (§10.6) and in the size-class table.
      await waitFor(() => expect(screen.getAllByText('111s').length).toBeGreaterThan(0))

      // Long enough for the abandoned run to land and try to win.
      await new Promise((resolve) => setTimeout(resolve, 150))

      expect(screen.getAllByText('111s').length).toBeGreaterThan(0)
      expect(screen.queryAllByText('999s')).toHaveLength(0)
    })

    // The app mounts inside `StrictMode` (`main.tsx`), which double-invokes
    // every state updater to shake out impure ones. `setPrevious` used to be
    // called from *inside* a `setRun` updater — the exact hazard `useCart`
    // already documents and avoids — so the ghost §10.6 asks for was being
    // computed from a re-entrant call rather than from a known value.
    it('ghosts exactly one run back, including under StrictMode', async () => {
      const user = userEvent.setup()
      serveRun()
      render(<StrictMode><DashboardScreen /></StrictMode>)
      await screen.findByText(/small-order p90/i)

      await user.click(screen.getByRole('button', { name: 'fifo' }))

      // Not a request count: StrictMode double-invokes the mount effect too, so
      // the run that lands here is the third request, not the second.
      //
      // The ghost is drawn only against a *different* policy at the same seed,
      // so its presence is the assertion that `previous` advanced once — to
      // the drr run — rather than skipping to the run just made.
      await waitFor(() => expect(screen.getByText(/than DRR on the same day/i)).toBeInTheDocument())
      expect(screen.queryByText(/than FIFO on the same day/i)).not.toBeInTheDocument()
    })

    it('runs once per hour button, which is one deliberate choice', async () => {
      const user = userEvent.setup()
      await renderRun()
      const before = requests.length

      await user.click(screen.getByRole('button', { name: /^13:00/ }))

      await waitFor(() => expect(requests).toHaveLength(before + 1))
      expect(requests[requests.length - 1].window_from).toBe(10800)
    })
  })

  describe('metric glosses', () => {
    it('explains what each figure measures once asked', async () => {
      const user = userEvent.setup()
      await renderRun()

      expect(screen.queryByText(/decides staffing/i)).not.toBeInTheDocument()
      await explain(user)

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
      const user = userEvent.setup()
      render(<DashboardScreen />)
      await screen.findByText(/small-order p90/i)
      await explain(user)

      expect(screen.getByText(/only 5 catering orders/i)).toBeInTheDocument()
      expect(screen.getByText(/slowest one rather than a percentile/i)).toBeInTheDocument()
    })

    it('trusts the figure once there are enough of them', async () => {
      const user = userEvent.setup()
      await renderRun()
      await explain(user)

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
      const user = userEvent.setup()
      render(<DashboardScreen />)
      await screen.findByText(/small-order p90/i)
      await explain(user)

      expect(screen.getByText(/only 4 small orders/i)).toBeInTheDocument()
    })

    // Zero is not a perfect score. Rendering it green was the same bug as the
    // 7+ percentile, reintroduced by the metric added to expose that one.
    it('shows no penalty rather than a flawless one when nothing is comparable', async () => {
      serveRun({
        metrics: {
          wait_by_drink_cost: { cheap: { orders: 0, p90: 0 }, dear: { orders: 0, p90: 0 }, ratio: 0, comparable: false },
        },
      })
      const user = userEvent.setup()
      render(<DashboardScreen />)

      expect(await screen.findByText('—')).toBeInTheDocument()
      expect(screen.queryByText('0.00×')).not.toBeInTheDocument()

      await explain(user)
      expect(screen.getByText(/not enough of one kind to compare/i)).toBeInTheDocument()
    })
  })

  // Below saturation every policy dispatches almost the same order, so the
  // dashboard must not invite a comparison it cannot support.
  describe('when the shop is too quiet to compare policies', () => {
    it('warns at low utilisation', async () => {
      serveRun({ metrics: { station_utilisation: 0.34 } })
      render(<DashboardScreen />)

      expect(await screen.findByText(/too quiet to compare arms/i)).toBeInTheDocument()
    })

    it('stays quiet once there is a queue to schedule', async () => {
      serveRun({ metrics: { station_utilisation: 0.8 } })
      render(<DashboardScreen />)
      await screen.findByText(/small-order p90/i)

      expect(screen.queryByText(/too quiet to compare arms/i)).not.toBeInTheDocument()
    })
  })

  // §13.4. The dashboard is the first browser surface behind the admin cookie,
  // and until this existed there was no way to obtain that cookie from a
  // browser at all — the screen said "sign in as admin first" and offered
  // nothing to sign in with.
  describe('the admin gate', () => {
    function serveSignedOut() {
      server.use(
        http.get('/api/v1/admin/session', () => new HttpResponse(null, { status: 401 })),
      )
    }

    it('asks for a sign-in when there is no session', async () => {
      serveSignedOut()
      render(<DashboardScreen />)

      expect(await screen.findByLabelText('email')).toBeInTheDocument()
      expect(screen.getByLabelText('password')).toBeInTheDocument()
    })

    // The other half, and the half a careless test leaves out: asserting only
    // that the form appears would pass against a screen that never renders the
    // dashboard at all.
    it('shows the dashboard when there is one', async () => {
      await renderRun()

      expect(screen.queryByLabelText('password')).not.toBeInTheDocument()
      expect(screen.getByText(/small-order p90/i)).toBeInTheDocument()
    })

    // Not a disabled panel — a config rail rendered to someone signed out shows
    // the shape of the live store's tuning surface (§10.6) and invites clicks
    // that silently 401.
    it('renders none of the panel while signed out', async () => {
      serveSignedOut()
      render(<DashboardScreen />)
      await screen.findByLabelText('email')

      expect(screen.queryByLabelText('seed')).not.toBeInTheDocument()
      expect(screen.queryByRole('group', { name: 'policy' })).not.toBeInTheDocument()
      expect(screen.queryByRole('button', { name: /run/i })).not.toBeInTheDocument()
    })

    // The session lives in a cookie the page cannot read, so every load asks
    // the server. Rendering the form during that answer flashes a sign-in
    // screen at an admin who is already signed in, on every reload.
    it('shows neither while it is still asking', async () => {
      let answer: (() => void) | undefined
      const held = new Promise<void>((resolve) => { answer = resolve })
      server.use(
        http.get('/api/v1/admin/session', async () => {
          await held
          return HttpResponse.json({ email: 'admin@bobagals.test' })
        }),
      )

      render(<DashboardScreen />)

      expect(screen.queryByLabelText('password')).not.toBeInTheDocument()
      expect(screen.queryByLabelText('seed')).not.toBeInTheDocument()

      answer?.()
      await screen.findByLabelText('seed')
    })

    it('opens the dashboard once the credentials are accepted', async () => {
      const user = userEvent.setup()
      serveSignedOut()
      serveRun()
      // `serveRun` registers a signed-in GET, so put the signed-out one back on
      // top: MSW resolves the most recently registered handler first.
      serveSignedOut()
      server.use(
        http.post('/api/v1/admin/session', () =>
          HttpResponse.json({ email: 'admin@bobagals.test' })),
      )
      render(<DashboardScreen />)
      await screen.findByLabelText('email')

      await user.type(screen.getByLabelText('email'), 'admin@bobagals.test')
      await user.type(screen.getByLabelText('password'), 'dev-only-not-a-real-password')
      await user.click(screen.getByRole('button', { name: /sign in/i }))

      expect(await screen.findByText(/small-order p90/i)).toBeInTheDocument()
    })

    // The server answers a wrong address and a wrong password identically, so
    // the endpoint cannot be asked "does this address have an account". A
    // helpful message here would undo that from the client side.
    it('repeats the refusal from the server without narrowing it down', async () => {
      const user = userEvent.setup()
      serveSignedOut()
      server.use(
        http.post('/api/v1/admin/session', () =>
          HttpResponse.json({ error: 'invalid email or password' }, { status: 401 })),
      )
      render(<DashboardScreen />)
      await screen.findByLabelText('email')

      await user.type(screen.getByLabelText('email'), 'nobody@bobagals.test')
      await user.type(screen.getByLabelText('password'), 'wrong')
      await user.click(screen.getByRole('button', { name: /sign in/i }))

      expect(await screen.findByRole('alert')).toHaveTextContent('invalid email or password')
      expect(screen.getByLabelText('email')).toBeInTheDocument()
    })

    it('returns to the form when the session goes away underneath a run', async () => {
      const user = userEvent.setup()
      await renderRun()
      server.use(
        http.post('/api/v1/admin/simulations', () => new HttpResponse(null, { status: 401 })),
      )

      await user.click(screen.getByRole('button', { name: /run/i }))

      expect(await screen.findByLabelText('password')).toBeInTheDocument()
      expect(screen.queryByLabelText('seed')).not.toBeInTheDocument()
    })

    it('signs out, so a back-office machine is not left on the dashboard', async () => {
      const user = userEvent.setup()
      await renderRun()
      server.use(
        http.delete('/api/v1/admin/session', () => new HttpResponse(null, { status: 204 })),
      )

      await user.click(screen.getByRole('button', { name: /sign out/i }))

      expect(await screen.findByLabelText('password')).toBeInTheDocument()
    })

    it('names who is signed in', async () => {
      await renderRun()

      expect(screen.getByText('admin@bobagals.test')).toBeInTheDocument()
    })
  })

  // §10.6: "Ship an 'Apply to store' action that writes the current config to
  // stores.scheduler_config, with a confirmation showing the diff." Thin by
  // design — the rail only exposes `policy` today.
  describe('apply to store', () => {
    let applyRequests: Record<string, unknown>[]

    function serveApply(overrides: { status?: number; errors?: string[] } = {}) {
      applyRequests = []
      server.use(
        http.patch('/api/v1/admin/scheduler_config', async ({ request }) => {
          const body = (await request.json()) as Record<string, unknown>
          applyRequests.push(body)

          if (overrides.status) {
            return HttpResponse.json({ errors: overrides.errors ?? [ 'invalid' ] }, { status: overrides.status })
          }

          const config = (body.scheduler_config as Record<string, unknown>) ?? {}
          return HttpResponse.json({
            store_id: 1,
            scheduler_config: defaultSchedulerConfig(config as Partial<SchedulerConfig>),
            editable: Object.keys(defaultSchedulerConfig()),
          })
        }),
      )
    }

    it('shows what is actually live once it loads', async () => {
      await renderRun()

      expect(await screen.findByText('live DRR')).toBeInTheDocument()
    })

    it('disables applying when the rail already matches what is live', async () => {
      await renderRun()
      await screen.findByText('live DRR')

      expect(screen.getByRole('button', { name: 'Apply to store' })).toBeDisabled()
    })

    it('enables applying once a different, appliable policy is picked', async () => {
      const user = userEvent.setup()
      await renderRun()
      await screen.findByText('live DRR')

      await user.click(screen.getByRole('button', { name: 'fifo' }))

      expect(screen.getByRole('button', { name: 'Apply to store' })).toBeEnabled()
    })

    it('never enables applying rr or sjf — the server would refuse them anyway', async () => {
      const user = userEvent.setup()
      await renderRun()
      await screen.findByText('live DRR')

      await user.click(screen.getByRole('button', { name: 'sjf' }))

      const button = screen.getByRole('button', { name: 'Apply to store' })
      expect(button).toBeDisabled()
      expect(button).toHaveAttribute('title', expect.stringContaining('simulator-only'))
    })

    it('shows the diff and waits for confirmation before writing anything', async () => {
      const user = userEvent.setup()
      serveApply()
      await renderRun()
      await screen.findByText('live DRR')

      await user.click(screen.getByRole('button', { name: 'fifo' }))
      await user.click(screen.getByRole('button', { name: 'Apply to store' }))

      expect(screen.getByText('apply policy: drr → fifo?')).toBeInTheDocument()
      expect(applyRequests).toHaveLength(0)
    })

    it('writes the change only once confirmed, and reflects what is now live', async () => {
      const user = userEvent.setup()
      serveApply()
      await renderRun()
      await screen.findByText('live DRR')

      await user.click(screen.getByRole('button', { name: 'fifo' }))
      await user.click(screen.getByRole('button', { name: 'Apply to store' }))
      await user.click(screen.getByRole('button', { name: 'Confirm' }))

      await waitFor(() => expect(applyRequests).toHaveLength(1))
      expect(applyRequests[0]).toEqual({ scheduler_config: { policy: 'fifo' } })
      expect(await screen.findByText('live FIFO')).toBeInTheDocument()
    })

    it('cancels without writing anything', async () => {
      const user = userEvent.setup()
      serveApply()
      await renderRun()
      await screen.findByText('live DRR')

      await user.click(screen.getByRole('button', { name: 'fifo' }))
      await user.click(screen.getByRole('button', { name: 'Apply to store' }))
      await user.click(screen.getByRole('button', { name: 'cancel' }))

      expect(screen.queryByText('apply policy: drr → fifo?')).not.toBeInTheDocument()
      expect(applyRequests).toHaveLength(0)
    })

    it('shows the server refusal without pretending the change landed', async () => {
      const user = userEvent.setup()
      serveApply({ status: 422, errors: [ 'policy must be one of: drr, fifo' ] })
      await renderRun()
      await screen.findByText('live DRR')

      await user.click(screen.getByRole('button', { name: 'fifo' }))
      await user.click(screen.getByRole('button', { name: 'Apply to store' }))
      await user.click(screen.getByRole('button', { name: 'Confirm' }))

      expect(await screen.findByText('policy must be one of: drr, fifo')).toBeInTheDocument()

      // Cancelling out of the failed confirmation proves nothing was applied
      // server-side — the rail is still reading the original live value.
      await user.click(screen.getByRole('button', { name: 'cancel' }))
      expect(screen.getByText('live DRR')).toBeInTheDocument()
    })

    // A background status read, not a user-initiated one — failing here must
    // not raise the same page-wide alert a failed run would.
    it('leaves the button disabled rather than alerting when the live read fails', async () => {
      server.use(http.get('/api/v1/admin/scheduler_config', () => new HttpResponse(null, { status: 500 })))
      await renderRun()

      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      expect(screen.getByRole('button', { name: 'Apply to store' })).toBeDisabled()
    })
  })
})

import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { http, HttpResponse } from 'msw'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { OrderingApp } from './OrderingApp'
import { server } from '../test/server'
import { FAILURES_BEFORE_PAUSED, POLL_INTERVAL_MS } from './useHealth'
import type { Menu, PlacedOrder } from '../api/types'

// jsdom has no ActionCable server. The status screen's live updates are covered
// in OrderStatusScreen.test.tsx; here the subscription only has to not explode.
vi.mock('../api/cable', () => ({ subscribe: () => () => {} }))

let posted: unknown[] = []

const MENU: Menu = {
  items: [
    {
      id: 1, name: 'Classic Milk Tea', category: 'milk_tea',
      price_cents: 550, base_prep_seconds: 45,
      option_groups: [
        {
          id: 1, name: 'Sweetness', min_select: 1, max_select: 1,
          options: [
            { id: 1, name: '100%', price_cents: 0, prep_seconds_delta: 0 },
            { id: 3, name: '50%', price_cents: 0, prep_seconds_delta: 0 },
          ],
        },
        // Optional *and* pick-one. Nothing in the fixture had this shape,
        // which is why "you can never un-choose it" went unnoticed: every
        // pick-one group here was required, where re-selecting is correct.
        {
          id: 5, name: 'Espresso shot', min_select: 0, max_select: 1,
          options: [
            { id: 30, name: 'Add a shot', price_cents: 150, prep_seconds_delta: 20 },
          ],
        },
        {
          id: 3, name: 'Toppings', min_select: 0, max_select: 2,
          options: [
            { id: 9, name: 'Boba pearls', price_cents: 75, prep_seconds_delta: 15 },
            { id: 11, name: 'Grass jelly', price_cents: 75, prep_seconds_delta: 15 },
            { id: 12, name: 'Pudding', price_cents: 100, prep_seconds_delta: 20 },
          ],
        },
      ],
    },
    {
      id: 2, name: 'Taro Slush', category: 'slush',
      price_cents: 650, base_prep_seconds: 90, option_groups: [],
    },
    // A required group that takes more than one, so "choose something" stays
    // reachable now that pick-exactly-one groups are defaulted.
    {
      id: 4, name: 'Tea Flight', category: 'specialty',
      price_cents: 900, base_prep_seconds: 120,
      option_groups: [
        {
          id: 4, name: 'Teas', min_select: 2, max_select: 3,
          options: [
            { id: 20, name: 'Jasmine', price_cents: 0, prep_seconds_delta: 0 },
            { id: 21, name: 'Oolong', price_cents: 0, prep_seconds_delta: 0 },
            { id: 22, name: 'Assam', price_cents: 0, prep_seconds_delta: 0 },
          ],
        },
      ],
    },
  ],
}

function placedOrder(overrides: Partial<PlacedOrder> = {}): PlacedOrder {
  return {
    pickup_code: 'R55Z', status: 'placed', source: 'web',
    customer_first_name: 'Tu', placed_at: '2026-08-09T02:01:22Z',
    promised_at: null, ready_at: null, total_cents: 625, quoted_wait_seconds: 240,
    items: [ { id: 1, label: 'Classic Milk Tea, 50%', status: 'queued', prep_seconds: 60, sequence: 1, remake: false } ],
    ...overrides,
  }
}

function serveMenu(menu: Menu = MENU) {
  posted = []
  server.use(
    // The kiosk polls this every 10s (§9.3), and `onUnhandledRequest: 'error'`
    // means an unserved probe fails the example rather than being ignored.
    http.get('/api/v1/health', () =>
      HttpResponse.json({ accepting_orders: true, store_name: 'Boba Gals' }),
    ),
    http.get('/api/v1/menu', () => HttpResponse.json(menu)),
    http.post('/api/v1/orders', async ({ request }) => {
      posted.push(await request.json())
      return HttpResponse.json(placedOrder(), { status: 201 })
    }),
    http.get('/api/v1/orders/:code', () => HttpResponse.json(placedOrder())),
  )
}

async function openMenu(mode: 'kiosk' | 'web' = 'web') {
  const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
  serveMenu()
  render(<OrderingApp mode={mode} />)
  await screen.findByRole('button', { name: /Classic Milk Tea/ })
  return user
}

/** Menu → customizer → cart, for the tests that start further along. */
async function addAMilkTea(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))
  await user.click(screen.getByText('50%'))
  await user.click(screen.getByRole('button', { name: /add to order/i }))
}

beforeEach(() => {
  posted = []
  // The kiosk's 10s poll needs a controllable clock; `shouldAdvanceTime` keeps
  // MSW and userEvent working around it (same pattern as KdsScreen.test.tsx).
  vi.useFakeTimers({ shouldAdvanceTime: true })
})

afterEach(() => {
  vi.useRealTimers()
})

// §9.3, locked in §3: "the kiosk polls /api/v1/health every 10s. Two
// consecutive failures → full-screen state."
describe('the kiosk when it cannot reach the shop (§9.3)', () => {
  function unreachable() {
    server.use(http.get('/api/v1/health', () => HttpResponse.error()))
  }

  it('says the shop is closed rather than blaming the network', async () => {
    serveMenu()
    server.use(
      http.get('/api/v1/health', () =>
        HttpResponse.json({ accepting_orders: false, store_name: 'Boba Gals' }),
      ),
    )
    render(<OrderingApp mode="kiosk" />)

    const refusal = await screen.findByRole('alert')
    expect(refusal).toHaveTextContent(/isn.t taking orders right now/i)
    expect(refusal).not.toHaveTextContent(/can.t reach/i)
  })

  it('refuses orders and says where to go instead', async () => {
    serveMenu()
    unreachable()
    render(<OrderingApp mode="kiosk" />)

    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS * FAILURES_BEFORE_PAUSED)

    const refusal = await screen.findByRole('alert')
    expect(refusal).toHaveTextContent(/ordering is paused/i)
    expect(refusal).toHaveTextContent(/order at the counter/i)
  })

  // §9.3: "The cart is preserved in memory so a brief blip doesn't lose an
  // in-progress order." Losing it would punish the customer for the shop's
  // wifi.
  it('keeps the cart through the outage', async () => {
    const user = await openMenu('kiosk')
    await addAMilkTea(user)
    expect(screen.getByRole('button', { name: /review/i })).toHaveTextContent('$5.50')

    unreachable()
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS * FAILURES_BEFORE_PAUSED)
    await screen.findByRole('alert')

    server.use(
      http.get('/api/v1/health', () =>
        HttpResponse.json({ accepting_orders: true, store_name: 'Boba Gals' }),
      ),
    )
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)

    expect(await screen.findByRole('button', { name: /review/i })).toHaveTextContent('$5.50')
  })

  // The web flow is a phone, which shows its own connectivity.
  it('never shows the refusal on the web', async () => {
    serveMenu()
    unreachable()
    render(<OrderingApp mode="web" />)

    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS * FAILURES_BEFORE_PAUSED)

    expect(screen.queryByText(/ordering is paused/i)).not.toBeInTheDocument()
  })
})

describe('OrderingApp (§9.3)', () => {
  describe('the menu', () => {
    it('groups drinks by category', async () => {
      await openMenu()

      expect(within(screen.getByRole('region', { name: 'milk_tea' })).getByText('Classic Milk Tea'))
        .toBeInTheDocument()
      expect(within(screen.getByRole('region', { name: 'slush' })).getByText('Taro Slush'))
        .toBeInTheDocument()
    })

    it('shows what each drink costs', async () => {
      await openMenu()

      expect(screen.getByText('$5.50')).toBeInTheDocument()
    })

    it('says so when the menu cannot be loaded', async () => {
      server.use(http.get('/api/v1/menu', () => HttpResponse.json({}, { status: 500 })))
      render(<OrderingApp mode="web" />)

      expect(await screen.findByRole('alert')).toHaveTextContent(/menu could not be loaded/i)
    })
  })

  // "min_select/max_select travel to the client because they decide the control
  // the ordering UI renders" (ADR-0003).
  describe('choosing options', () => {
    it('renders a radio group when at most one may be chosen', async () => {
      const user = await openMenu()

      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      expect(screen.getByRole('radio', { name: /50%/ })).toBeInTheDocument()
    })

    it('renders checkboxes when several may be chosen', async () => {
      const user = await openMenu()

      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      expect(screen.getByRole('checkbox', { name: /Boba pearls/ })).toBeInTheDocument()
    })

    it('replaces the choice in a pick-one group rather than adding to it', async () => {
      const user = await openMenu()
      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      await user.click(screen.getByText('100%'))
      await user.click(screen.getByText('50%'))

      expect(screen.getByRole('radio', { name: /50%/ })).toBeChecked()
      expect(screen.getByRole('radio', { name: /100%/ })).not.toBeChecked()
    })

    // §9.3 puts this on a kiosk with no back button inside the sheet: if a
    // choice cannot be undone, the only way out is to cancel the drink and
    // build it again. Required pick-one groups are exempt — there, one option
    // must be chosen, so re-selecting the current one is the right no-op.
    it('lets an optional pick-one choice be taken back', async () => {
      const user = await openMenu()
      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      await user.click(screen.getByText('Add a shot'))
      expect(screen.getByRole('radio', { name: /Add a shot/ })).toBeChecked()

      await user.click(screen.getByText('Add a shot'))
      expect(screen.getByRole('radio', { name: /Add a shot/ })).not.toBeChecked()
    })

    // The clearing above works through `onClick` rather than `onChange`, which
    // is only correct if a keyboard still activates the control. The inputs are
    // `sr-only`, so this is the path a screen-reader user takes.
    it('toggles an optional pick-one choice from the keyboard', async () => {
      const user = await openMenu()
      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      const shot = screen.getByRole('radio', { name: /Add a shot/ })
      shot.focus()
      await user.keyboard(' ')
      expect(shot).toBeChecked()

      await user.keyboard(' ')
      expect(shot).not.toBeChecked()
    })

    it('keeps a required pick-one choice when it is tapped again', async () => {
      const user = await openMenu()
      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      await user.click(screen.getByText('100%'))
      await user.click(screen.getByText('100%'))

      expect(screen.getByRole('radio', { name: /100%/ })).toBeChecked()
    })

    it('refuses more toppings than the group allows', async () => {
      const user = await openMenu()
      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      await user.click(screen.getByText('Boba pearls'))
      await user.click(screen.getByText('Grass jelly'))
      await user.click(screen.getByText('Pudding'))

      expect(screen.getByRole('checkbox', { name: /Pudding/ })).not.toBeChecked()
    })

    // Sweetness and ice are three taps on every order in the shop. Defaulting
    // the pick-exactly-one groups to the menu's first option makes the common
    // drink one tap (§9.3 — a kiosk is used standing up).
    it('preselects the first choice in a pick-one group', async () => {
      const user = await openMenu()

      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      expect(screen.getByRole('radio', { name: /100%/ })).toBeChecked()
      expect(screen.getByRole('button', { name: /add to order/i })).toBeEnabled()
    })

    // Guessing at a real choice is worse than asking, so a required group that
    // takes more than one gets no default.
    it('does not guess at a required group that takes several', async () => {
      const user = await openMenu()

      await user.click(screen.getByRole('button', { name: /Tea Flight/ }))

      expect(screen.getByRole('checkbox', { name: /Jasmine/ })).not.toBeChecked()
    })

    // The server validates this too (`CreateOrder`); this copy exists so the
    // customer is told before they tap, not after.
    it('will not add a drink with a required choice missing', async () => {
      const user = await openMenu()

      await user.click(screen.getByRole('button', { name: /Tea Flight/ }))

      expect(screen.getByRole('button', { name: /add to order/i })).toBeDisabled()
    })

    it('prices the options into the running total', async () => {
      const user = await openMenu()
      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))

      await user.click(screen.getByText('50%'))
      await user.click(screen.getByText('Boba pearls'))

      expect(screen.getByRole('dialog')).toHaveTextContent('$6.25')
    })
  })

  describe('the cart', () => {
    it('stays out of the way until there is something in it', async () => {
      await openMenu()

      expect(screen.queryByRole('button', { name: /review/i })).not.toBeInTheDocument()
    })

    it('totals what has been added', async () => {
      const user = await openMenu()

      await addAMilkTea(user)

      expect(screen.getByRole('button', { name: /review/i })).toHaveTextContent('$5.50')
    })

    it('counts two of the same drink as two', async () => {
      const user = await openMenu()

      await addAMilkTea(user)
      await addAMilkTea(user)

      expect(screen.getByText('2 drinks')).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /review/i })).toHaveTextContent('$11.00')
    })

    it('adds several of one drink in a single pass', async () => {
      const user = await openMenu()

      await user.click(screen.getByRole('button', { name: /Classic Milk Tea/ }))
      await user.click(screen.getByRole('button', { name: /one more quantity of Classic Milk Tea/i }))
      await user.click(screen.getByRole('button', { name: /one more quantity of Classic Milk Tea/i }))
      await user.click(screen.getByRole('button', { name: /add 3 to order/i }))

      expect(screen.getByText('3 drinks')).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /review/i })).toHaveTextContent('$16.50')
    })

    it('changes a quantity at checkout', async () => {
      const user = await openMenu()
      await addAMilkTea(user)
      await user.click(screen.getByRole('button', { name: /review/i }))

      await user.click(screen.getByRole('button', { name: /one more quantity of Classic Milk Tea/i }))

      expect(screen.getByRole('status', { name: /quantity of Classic Milk Tea/i })).toHaveTextContent('2')
      // The line and the grand total, which for a single line are the same
      // number arrived at two ways.
      expect(screen.getAllByText('$11.00')).toHaveLength(2)
    })

    // A row in the cart that is not in the order would be worse than gone.
    it('drops a line stepped below one at checkout', async () => {
      const user = await openMenu()
      await addAMilkTea(user)
      await user.click(screen.getByRole('button', { name: /review/i }))

      await user.click(screen.getByRole('button', { name: /one fewer quantity of Classic Milk Tea/i }))

      expect(screen.queryByText('Classic Milk Tea')).not.toBeInTheDocument()
    })

    // Stepping the last line off the order is allowed — this is the last screen
    // before it is placed, so it has to be. Nothing then sent the customer back
    // to the menu, so "Place order" sat there live above an empty list, and
    // pressing it posted an order with no drinks in it.
    it('will not place an order once the last line has been removed', async () => {
      const user = await openMenu()
      await addAMilkTea(user)
      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')

      await user.click(screen.getByRole('button', { name: /one fewer quantity of Classic Milk Tea/i }))

      expect(screen.getByRole('button', { name: /place order/i })).toBeDisabled()
      expect(screen.getByText(/cart is empty/i)).toBeInTheDocument()

      await user.click(screen.getByRole('button', { name: /place order/i }))
      expect(posted).toHaveLength(0)
    })
  })

  describe('checkout', () => {
    it('sends the drinks, the name, and the source', async () => {
      const user = await openMenu('web')
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')
      await user.click(screen.getByRole('button', { name: /place order/i }))

      await waitFor(() => expect(posted).toEqual([
        {
          order: {
            source: 'web',
            customer_first_name: 'Tu',
            items: [ { menu_item_id: 1, option_ids: [ 3 ] } ],
          },
        },
      ]))
    })

    // §9.7: web orders collect a phone for the single ready SMS; a kiosk order
    // has nobody to text, and `Order` rejects the field outright on one.
    it('collects a phone on the web', async () => {
      const user = await openMenu('web')
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))

      expect(screen.getByLabelText('phone')).toBeInTheDocument()
    })

    it('does not collect a phone at the kiosk', async () => {
      const user = await openMenu('kiosk')
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))

      expect(screen.queryByLabelText('phone')).not.toBeInTheDocument()
    })

    // A number with a typo is worse than no number: the order goes through, the
    // drinks get made, and the ready text (§9.7) goes nowhere. The server
    // validates too — this is so the customer hears about it while they can
    // still fix it.
    it('refuses to place the order when the phone could not receive a text', async () => {
      const user = await openMenu('web')
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')
      await user.type(screen.getByLabelText('phone'), '555')
      await user.click(screen.getByRole('button', { name: /place order/i }))

      expect(await screen.findByRole('alert')).toHaveTextContent(/does not look like a number/i)
      expect(posted).toHaveLength(0)
    })

    it('accepts the formatting people actually type', async () => {
      const user = await openMenu('web')
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')
      await user.type(screen.getByLabelText('phone'), '(555) 555-0123')
      await user.click(screen.getByRole('button', { name: /place order/i }))

      await waitFor(() => expect(posted).toHaveLength(1))
      expect(posted[0]).toMatchObject({ order: { customer_phone: '(555) 555-0123' } })
    })

    // Leaving the error up while someone is correcting the field reads as
    // "still wrong", so it clears on the first keystroke.
    it('clears the complaint as soon as they start fixing it', async () => {
      const user = await openMenu('web')
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')
      await user.type(screen.getByLabelText('phone'), '555')
      await user.click(screen.getByRole('button', { name: /place order/i }))
      await screen.findByRole('alert')

      await user.type(screen.getByLabelText('phone'), '5550123')

      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    })

    // The phone stays optional. Most web customers just wait.
    it('places a web order with no phone at all', async () => {
      const user = await openMenu('web')
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')
      await user.click(screen.getByRole('button', { name: /place order/i }))

      await waitFor(() => expect(posted).toHaveLength(1))
      expect(JSON.stringify(posted[0])).not.toContain('customer_phone')
    })

    it('places a kiosk order as a kiosk order', async () => {
      const user = await openMenu('kiosk')
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')
      await user.click(screen.getByRole('button', { name: /place order/i }))

      await waitFor(() => expect(posted).toHaveLength(1))
      expect(posted[0]).toMatchObject({ order: { source: 'kiosk' } })
      expect(JSON.stringify(posted[0])).not.toContain('customer_phone')
    })

    // Payment is locked for v1: record `total_cents`, settle at the register
    // (§9.3). A card field here would be a design change, not a feature.
    it('asks for no payment details', async () => {
      const user = await openMenu()
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))

      expect(screen.getByText(/pay at the counter/i)).toBeInTheDocument()
      expect(screen.queryByLabelText(/card/i)).not.toBeInTheDocument()
    })

    it('shows the pickup code once the order is placed', async () => {
      const user = await openMenu()
      await addAMilkTea(user)

      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')
      await user.click(screen.getByRole('button', { name: /place order/i }))

      expect(await screen.findByText('R55Z')).toBeInTheDocument()
    })

    // §9.3, locked: no optimistic accept. A customer holding a receipt for a
    // drink the kitchen never saw is strictly worse than a clear refusal.
    it('keeps the cart when the order is refused', async () => {
      const user = await openMenu()
      await addAMilkTea(user)
      await user.click(screen.getByRole('button', { name: /review/i }))
      await user.type(screen.getByLabelText('first name'), 'Tu')

      server.use(
        http.post('/api/v1/orders', () =>
          // `{ errors: [...] }` — the shape Api::V1::BaseController#unprocessable
          // actually renders for every 422. This fixture used the singular
          // `{ error: ... }`, which the API never sends for a 422, so it passed
          // against a payload production does not produce and hid the fact that
          // apiPost read the wrong key and dropped every 422 message.
          HttpResponse.json({ errors: ['store is not accepting orders'] }, { status: 422 }),
        ),
      )
      await user.click(screen.getByRole('button', { name: /place order/i }))

      expect(await screen.findByRole('alert')).toHaveTextContent(/not accepting orders/i)

      await user.click(screen.getByRole('button', { name: /back/i }))
      expect(screen.getByRole('button', { name: /review/i })).toHaveTextContent('$5.50')
    })
  })
})

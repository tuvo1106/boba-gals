import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { http, HttpResponse } from 'msw'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { KdsScreen } from './KdsScreen'
import { server } from '../test/server'
import type { KdsItem, QueueUpdate } from '../api/types'

// jsdom has no ActionCable server. What matters is that a broadcast reaches the
// screen, so the subscription is replaced with a handle the test can push through.
let broadcast: (update: QueueUpdate) => void = () => {}

vi.mock('../api/cable', () => ({
  subscribe: ({
    onReceived,
    onConnected,
  }: {
    onReceived: (data: QueueUpdate) => void
    onConnected?: () => void
  }) => {
    broadcast = onReceived
    onConnected?.()
    return () => {}
  },
}))

function drink(overrides: Partial<KdsItem> = {}): KdsItem {
  return {
    id: 1, label: 'Classic Milk Tea, 50%, LESS ICE', status: 'queued', prep_seconds: 45,
    pickup_code: 'A1B2', sequence: 1, order_size: 1, remake: false,
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
        barista: { id: 1, name: 'Mei' }, station: { id: 2, name: 'Bar 2' },
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
  const user = userEvent.setup()
  serveKds(snapshot)
  render(<KdsScreen />)
  await signIn(user)
  // Waits on the sign-out control rather than on header text: with an empty
  // queue the word "waiting" appears in both the header label and the
  // "Nothing waiting" button, and the query would match two nodes.
  await screen.findByRole('button', { name: /sign out/i })
  return user
}

beforeEach(() => {
  broadcast = () => {}
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
      const user = userEvent.setup()
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
      await open(queueUpdate({ in_progress: [ drink({ status: 'in_progress', sequence: 2, order_size: 5 }) ] }))

      expect(screen.getByText('2 of 5')).toBeInTheDocument()
    })

    it('does not clutter a single-drink order with a position', async () => {
      await open(queueUpdate({ in_progress: [ drink({ status: 'in_progress', sequence: 1, order_size: 1 }) ] }))

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

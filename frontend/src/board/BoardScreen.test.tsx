import { act, render, screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { BoardScreen } from './BoardScreen'
import { server } from '../test/server'
import type { BoardUpdate } from '../api/types'

// The websocket itself is ActionCable's business, and jsdom has no server to
// talk to. What matters here is that a broadcast reaches the screen, so the
// subscription is replaced with a handle the test can push through.
let broadcast: (update: BoardUpdate) => void = () => {}
let connect: () => void = () => {}
// The subscription only happens once the first REST read has landed, because
// that is where the store id comes from. Tests must wait for this rather than
// for anything on screen: "Connecting…" is present from the very first render,
// so finding it proves nothing about whether `connect` has been captured yet.
let subscribed = false

vi.mock('../api/cable', () => ({
  subscribe: ({
    onReceived,
    onConnected,
  }: {
    onReceived: (data: BoardUpdate) => void
    onConnected?: () => void
  }) => {
    broadcast = onReceived
    connect = () => onConnected?.()
    subscribed = true
    return () => {}
  },
}))

function boardPayload(overrides: Partial<BoardUpdate> = {}): BoardUpdate {
  return { type: 'board_update', store_id: 1, making: [], ready: [], ...overrides }
}

function serveBoard(payload: BoardUpdate) {
  server.use(http.get('/api/v1/board', () => HttpResponse.json(payload)))
}

const sarah = {
  first_name: 'Sarah',
  pickup_code: 'K7QF',
  items: ['Thai Tea, 50%', 'Taro Slush'],
  eta_seconds: 240,
}

describe('BoardScreen', () => {
  beforeEach(() => {
    broadcast = () => {}
    connect = () => {}
    subscribed = false
  })

  it('renders drinks being made with a wait in minutes', async () => {
    serveBoard(boardPayload({ making: [sarah] }))

    render(<BoardScreen />)

    // Await the content, not the column: both columns render immediately and
    // empty, so awaiting the region resolves before the fetch has landed and
    // every synchronous query after it races.
    await screen.findByText('Sarah')

    const making = screen.getByRole('region', { name: 'Making' })
    expect(within(making).getByText('Sarah')).toBeInTheDocument()
    expect(within(making).getByText('K7QF')).toBeInTheDocument()
    expect(within(making).getByText('4 min')).toBeInTheDocument()
  })

  // Names only. The options are in the label because the KDS needs them
  // (§9.4); a customer reading the board from fifteen feet does not, and one
  // drink with toppings filled the whole line on its own.
  it('lists the drinks in an order without their options', async () => {
    serveBoard(boardPayload({ making: [sarah] }))

    render(<BoardScreen />)

    expect(await screen.findByText('Thai Tea · Taro Slush')).toBeInTheDocument()
  })

  it('renders ready orders in their own column', async () => {
    serveBoard(
      boardPayload({
        ready: [
          {
            first_name: 'Ali',
            pickup_code: 'M4XR',
            ready_since_seconds: 20,
            picked_up_seconds_ago: null,
          },
        ],
      }),
    )

    render(<BoardScreen />)
    await screen.findByText('Ali')

    const ready = screen.getByRole('region', { name: 'Ready' })
    expect(within(ready).getByText('Ali')).toBeInTheDocument()
    expect(within(ready).getByText('Just now')).toBeInTheDocument()
  })

  it('tells staff when both columns are empty', async () => {
    serveBoard(boardPayload())

    render(<BoardScreen />)

    expect(await screen.findAllByText('Nothing right now')).toHaveLength(2)
  })

  // §9.2: payloads are whole snapshots, so a broadcast replaces the view rather
  // than merging into it. A row that left the server's board has to leave the
  // screen.
  it('replaces the whole board when a broadcast arrives', async () => {
    serveBoard(boardPayload({ making: [sarah] }))

    render(<BoardScreen />)
    await screen.findByText('Sarah')
    // "Sarah" on screen does not mean the subscription exists. The store id
    // comes from the REST snapshot, so `subscribe` runs in a passive effect
    // *after* the render that puts her there — and broadcasting before that
    // captures nothing but the initial no-op, silently. This is the wait the
    // `subscribed` flag exists for.
    await waitFor(() => expect(subscribed).toBe(true))

    act(() =>
      broadcast(
        boardPayload({
          ready: [
            {
              first_name: 'Sarah',
              pickup_code: 'K7QF',
              ready_since_seconds: 5,
              picked_up_seconds_ago: null,
            },
          ],
        }),
      ),
    )

    // Await something only the new snapshot renders. "Sarah" is no good here —
    // she is already on screen under Making, so findByText would match the old
    // state instantly and the assertions below would race the re-render.
    await screen.findByText('Just now')

    expect(within(screen.getByRole('region', { name: 'Ready' })).getByText('Sarah'))
      .toBeInTheDocument()
    expect(within(screen.getByRole('region', { name: 'Making' })).queryByText('Sarah'))
      .not.toBeInTheDocument()
  })

  describe('the connection indicator', () => {
    it('shows a status while the socket is not yet live', async () => {
      serveBoard(boardPayload())

      render(<BoardScreen />)

      expect(await screen.findByRole('status')).toHaveTextContent('Connecting…')
    })

    // A customer should never be asked to care that a websocket dropped.
    it('disappears once the socket connects', async () => {
      serveBoard(boardPayload())

      render(<BoardScreen />)
      await waitFor(() => expect(subscribed).toBe(true))
      act(connect)

      await waitFor(() => expect(screen.queryByRole('status')).not.toBeInTheDocument())
    })

    it('reports a failed first read rather than rendering an empty board silently', async () => {
      server.use(http.get('/api/v1/board', () => HttpResponse.error()))

      render(<BoardScreen />)

      // waitFor, not findByRole: the indicator is on screen from the first
      // render reading "Connecting…", so asserting on whatever is found first
      // races the fetch rejecting.
      await waitFor(() =>
        expect(screen.getByRole('status')).toHaveTextContent('Reconnecting…'),
      )
    })
  })
})

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
  })

  it('renders drinks being made with a wait in minutes', async () => {
    serveBoard(boardPayload({ making: [sarah] }))

    render(<BoardScreen />)

    const making = await screen.findByRole('region', { name: 'Making' })
    expect(within(making).getByText('Sarah')).toBeInTheDocument()
    expect(within(making).getByText('K7QF')).toBeInTheDocument()
    expect(within(making).getByText('4 min')).toBeInTheDocument()
  })

  it('lists the drinks in an order', async () => {
    serveBoard(boardPayload({ making: [sarah] }))

    render(<BoardScreen />)

    expect(await screen.findByText('Thai Tea, 50% · Taro Slush')).toBeInTheDocument()
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

    const ready = await screen.findByRole('region', { name: 'Ready' })
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

    const ready = await screen.findByRole('region', { name: 'Ready' })
    expect(within(ready).getByText('Sarah')).toBeInTheDocument()
    expect(within(await screen.findByRole('region', { name: 'Making' })).queryByText('Sarah'))
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
      await screen.findByRole('status')
      act(connect)

      await waitFor(() => expect(screen.queryByRole('status')).not.toBeInTheDocument())
    })

    it('reports a failed first read rather than rendering an empty board silently', async () => {
      server.use(http.get('/api/v1/board', () => HttpResponse.error()))

      render(<BoardScreen />)

      expect(await screen.findByRole('status')).toHaveTextContent('Reconnecting…')
    })
  })
})

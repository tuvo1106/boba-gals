import { describe, expect, it } from 'vitest'
import { age, PICKED_UP_PERSISTENCE_SECONDS, READY_BOARD_TTL_SECONDS } from './useBoard'
import type { BoardUpdate } from '../api/types'

function board(overrides: Partial<BoardUpdate> = {}): BoardUpdate {
  return { type: 'board_update', store_id: 1, making: [], ready: [], ...overrides }
}

function making(eta: number) {
  return { first_name: 'Sarah', pickup_code: 'K7QF', items: ['Thai Tea'], eta_seconds: eta }
}

function ready(readySince: number, pickedUpAgo: number | null = null) {
  return {
    first_name: 'Sarah',
    pickup_code: 'K7QF',
    ready_since_seconds: readySince,
    picked_up_seconds_ago: pickedUpAgo,
  }
}

// The server is the source of truth; this arithmetic keeps the screen honest
// between broadcasts. A quiet store can go minutes without a transition, and a
// frozen "4 min" is how a board teaches people to stop believing it.
describe('age', () => {
  it('counts an ETA down', () => {
    expect(age(board({ making: [making(300)] }), 45).making[0].eta_seconds).toBe(255)
  })

  // A negative countdown is the board admitting it was wrong, which reads worse
  // than sitting at "Almost ready" until the drink actually lands.
  it('never counts an ETA below zero', () => {
    expect(age(board({ making: [making(30)] }), 90).making[0].eta_seconds).toBe(0)
  })

  it('counts time in the ready column up', () => {
    expect(age(board({ ready: [ready(10)] }), 45).ready[0].ready_since_seconds).toBe(55)
  })

  describe('retiring rows', () => {
    it('keeps a ready row inside the board TTL', () => {
      expect(age(board({ ready: [ready(0)] }), READY_BOARD_TTL_SECONDS).ready).toHaveLength(1)
    })

    it('drops a ready row past the board TTL', () => {
      expect(age(board({ ready: [ready(0)] }), READY_BOARD_TTL_SECONDS + 1).ready).toHaveLength(0)
    })

    // §9.5's 90-second courtesy is measured from collection, so a collected row
    // stays even once its ready_since is older than the board TTL.
    it('keeps a collected row for 90 seconds regardless of how long it was ready', () => {
      const aged = age(board({ ready: [ready(READY_BOARD_TTL_SECONDS + 600, 0)] }), 30)

      expect(aged.ready).toHaveLength(1)
      expect(aged.ready[0].picked_up_seconds_ago).toBe(30)
    })

    it('drops a collected row after 90 seconds', () => {
      const aged = age(board({ ready: [ready(200, 0)] }), PICKED_UP_PERSISTENCE_SECONDS + 1)

      expect(aged.ready).toHaveLength(0)
    })
  })

  it('leaves the snapshot it was given untouched', () => {
    const snapshot = board({ making: [making(300)], ready: [ready(10)] })

    age(snapshot, 60)

    expect(snapshot.making[0].eta_seconds).toBe(300)
    expect(snapshot.ready[0].ready_since_seconds).toBe(10)
  })
})

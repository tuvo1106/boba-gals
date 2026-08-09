import { describe, expect, it } from 'vitest'
import { formatPrice, formatPriceDelta, formatProgress, formatWaitRange } from './money'

describe('formatPrice', () => {
  it('renders cents as dollars', () => {
    expect(formatPrice(1175)).toBe('$11.75')
  })

  it('keeps both decimal places on a round number', () => {
    expect(formatPrice(600)).toBe('$6.00')
  })

  it('handles a free item', () => {
    expect(formatPrice(0)).toBe('$0.00')
  })
})

describe('formatPriceDelta', () => {
  // A "+$0.00" next to every sweetness level is noise on a screen that has to
  // be readable standing up.
  it('says nothing when an option is free', () => {
    expect(formatPriceDelta(0)).toBe('')
  })

  it('signs a surcharge', () => {
    expect(formatPriceDelta(75)).toBe('+$0.75')
  })
})

describe('formatWaitRange', () => {
  // A single number invites being read as a promise, and this one moves: §6.1
  // shares capacity with orders arriving behind, which is what pushed a
  // measured p90 of 257s onto an overtaken small order at peak demand.
  it('quotes a range, not a point', () => {
    expect(formatWaitRange(260)).toBe('4–6 min')
  })

  it('always leaves room to move', () => {
    expect(formatWaitRange(65)).toBe('1–2 min')
  })

  it('never rounds a real wait down to nothing', () => {
    expect(formatWaitRange(20)).toBe('1–2 min')
  })

  // Not "0 min", and not a range either — there is nothing left to estimate.
  it('stops estimating when there is nothing left to wait for', () => {
    expect(formatWaitRange(0)).toBe('Any moment now')
  })

  it('widens with the estimate, because a long wait is a less certain one', () => {
    expect(formatWaitRange(600)).toBe('10–14 min')
  })
})

describe('formatProgress', () => {
  // The one thing on the screen that cannot go backwards.
  it('counts the drinks that are done', () => {
    expect(formatProgress(2, 5)).toBe('2 of 5 made')
  })

  it('says so before anything is made', () => {
    expect(formatProgress(0, 3)).toBe('0 of 3 made')
  })

  // "1 of 1" is noise, the same judgement the KDS makes about "1 of 1" (§9.4).
  it('stays quiet about a single-drink order', () => {
    expect(formatProgress(0, 1)).toBeNull()
  })

  it('stays quiet about an order with nothing in it', () => {
    expect(formatProgress(0, 0)).toBeNull()
  })
})

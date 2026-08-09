import { describe, expect, it } from 'vitest'
import { formatPrice, formatPriceDelta, formatWaitMinutes } from './money'

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

describe('formatWaitMinutes', () => {
  // Deliberately coarse. §7.3's estimate is not accurate to the second, and a
  // customer reading "4:37" believes it to the second.
  it('rounds to whole minutes', () => {
    expect(formatWaitMinutes(260)).toBe('about 4 minutes')
  })

  it('never rounds a real wait down to zero', () => {
    expect(formatWaitMinutes(20)).toBe('about a minute')
  })

  it('handles a projection of nothing at all', () => {
    expect(formatWaitMinutes(0)).toBe('about a minute')
  })

  it('reads as singular at one minute', () => {
    expect(formatWaitMinutes(65)).toBe('about a minute')
  })
})

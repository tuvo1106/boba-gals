import { describe, expect, it } from 'vitest'
import { formatEta, formatReadySince, summariseDrinks } from './format'

describe('formatEta', () => {
  // §9.5: "ETA in minutes (never seconds; false precision reads as a lie)."
  it('never shows seconds', () => {
    for (const seconds of [121, 200, 599, 3600]) {
      expect(formatEta(seconds)).toMatch(/^\d+ min$/)
    }
  })

  it('shows "Almost ready" under two minutes', () => {
    expect(formatEta(0)).toBe('Almost ready')
    expect(formatEta(119)).toBe('Almost ready')
    expect(formatEta(120)).toBe('Almost ready')
  })

  // Rounding up, not down: a customer told "3 min" who waits 3:40 feels lied
  // to, and rounding down guarantees that on every value.
  it('rounds up to the next whole minute', () => {
    expect(formatEta(121)).toBe('3 min')
    expect(formatEta(180)).toBe('3 min')
    expect(formatEta(181)).toBe('4 min')
  })
})

describe('formatReadySince', () => {
  it('reads "Just now" for the first minute', () => {
    expect(formatReadySince(0)).toBe('Just now')
    expect(formatReadySince(59)).toBe('Just now')
  })

  it('counts whole minutes after that', () => {
    expect(formatReadySince(60)).toBe('1 min ago')
    expect(formatReadySince(119)).toBe('1 min ago')
    expect(formatReadySince(240)).toBe('4 min ago')
  })
})

describe('summariseDrinks (§9.5)', () => {
  it('drops the options, which are the barista\'s business and not the customer\'s', () => {
    expect(summariseDrinks([ 'Classic Milk Tea, 50%, Less ice, Boba pearls' ]))
      .toBe('Classic Milk Tea')
  })

  it('lists two different drinks', () => {
    expect(summariseDrinks([ 'Taro Slush', 'Thai Tea, 100%' ])).toBe('Taro Slush · Thai Tea')
  })

  // The ordering app has a quantity control, so six of one drink is a normal
  // order now. Listing it six times tells nobody anything.
  it('counts repeats rather than repeating them', () => {
    expect(summariseDrinks([ 'Classic Milk Tea', 'Classic Milk Tea', 'Classic Milk Tea' ]))
      .toBe('Classic Milk Tea ×3')
  })

  it('counts repeats that differ only by their options', () => {
    expect(summariseDrinks([ 'Thai Tea, 100%', 'Thai Tea, 50%, No ice' ])).toBe('Thai Tea ×2')
  })

  // §2 exists for the fifteen-drink catering order, and the board has one line
  // for it. Overflowing is what it did before.
  it('summarises an order too long to list', () => {
    expect(summariseDrinks([ 'Taro Slush', 'Thai Tea', 'Matcha Latte', 'Mango Slush' ]))
      .toBe('Taro Slush · Thai Tea +2 more')
  })

  it('counts the drinks left over, not the kinds', () => {
    const items = [ 'Taro Slush', 'Thai Tea', 'Matcha Latte', 'Matcha Latte', 'Matcha Latte' ]

    expect(summariseDrinks(items)).toBe('Taro Slush · Thai Tea +3 more')
  })

  it('handles an order with nothing in it', () => {
    expect(summariseDrinks([])).toBe('')
  })
})

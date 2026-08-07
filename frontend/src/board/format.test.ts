import { describe, expect, it } from 'vitest'
import { formatEta, formatReadySince } from './format'

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

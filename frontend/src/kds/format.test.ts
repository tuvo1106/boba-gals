import { describe, expect, it } from 'vitest'
import { formatWait } from './format'

describe('formatWait', () => {
  it('reads as minutes and seconds', () => {
    expect(formatWait(440)).toBe('7:20')
    expect(formatWait(65)).toBe('1:05')
  })

  it('never shows a negative wait', () => {
    expect(formatWait(0)).toBe('0:00')
    expect(formatWait(-5)).toBe('0:00')
  })

  // "1204:00" is correct and unreadable, and reachable — a drink queued before
  // close and still waiting next morning is exactly what this figure exists to
  // make impossible to miss.
  it('falls back to hours rather than counting minutes forever', () => {
    expect(formatWait(3600)).toBe('1h 0m')
    expect(formatWait(72_240)).toBe('20h 4m')
  })
})

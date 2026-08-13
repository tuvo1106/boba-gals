import { render, screen, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { StaffingCurveTable } from './StaffingCurveTable'
import type { StaffingCurve, StaffingCurveHour } from '../api/types'

function hour(overrides: Partial<StaffingCurveHour> = {}): StaffingCurveHour {
  return {
    hour: 10, stations: 2, achieved: true, p90: 180, orders: 40, p90_meaningful: true,
    ...overrides,
  }
}

function curve(overrides: Partial<StaffingCurve> = {}): StaffingCurve {
  return {
    seed: 7, seeds: 1, demand_multiplier: 1.6, target_seconds: 600,
    hours: [
      hour({ hour: 10, stations: 1, p90: 120, orders: 20 }),
      hour({ hour: 16, stations: 5, p90: 540, orders: 210 }),
      hour({ hour: 20, stations: 2, p90: 210, orders: 45 }),
    ],
    ...overrides,
  }
}

describe('StaffingCurveTable (§10.5 #3)', () => {
  it('names the target it staffed against', () => {
    render(<StaffingCurveTable curve={curve()} />)

    expect(screen.getByText('Staffing curve — p90 under 600s')).toBeInTheDocument()
  })

  it('names the seed and day count, so the schedule can be re-run', () => {
    render(<StaffingCurveTable curve={curve({ seeds: 12 })} />)

    expect(screen.getByText(/seed 7/)).toBeInTheDocument()
    expect(screen.getByText(/12 days pooled/)).toBeInTheDocument()
  })

  it('lists every hour with the stations it needs', () => {
    render(<StaffingCurveTable curve={curve()} />)

    const table = screen.getByRole('table')
    expect(within(table).getByText('10:00')).toBeInTheDocument()
    expect(within(table).getByText('16:00')).toBeInTheDocument()
    expect(within(table).getByText('20:00')).toBeInTheDocument()
    expect(within(table).getAllByText('5')).toHaveLength(1)
  })

  it('warns when an hour still misses target at the widest count tried', () => {
    render(<StaffingCurveTable curve={curve({ hours: [ hour({ achieved: false, stations: 8 }) ] })} />)

    expect(screen.getByText(/still misses target/i)).toBeInTheDocument()
  })

  it('stays quiet when every hour holds target', () => {
    render(<StaffingCurveTable curve={curve()} />)

    expect(screen.queryByText(/still misses target/i)).not.toBeInTheDocument()
  })

  it('flags an hour too thin to be a percentile', () => {
    render(<StaffingCurveTable curve={curve({ hours: [ hour({ p90_meaningful: false, orders: 4 }) ] })} />)

    expect(screen.getByTitle(/too few orders in this hour/i)).toBeInTheDocument()
  })

  it('warns that a single day cannot separate a small gap from noise', () => {
    render(<StaffingCurveTable curve={curve()} />)

    expect(screen.getByText(/one day only/i)).toBeInTheDocument()
  })

  it('drops the warning once several days are pooled', () => {
    render(<StaffingCurveTable curve={curve({ seeds: 12 })} />)

    expect(screen.queryByText(/one day only/i)).not.toBeInTheDocument()
  })
})

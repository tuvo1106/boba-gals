import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { BreakingPointChart } from './BreakingPointChart'
import type { BreakingPoint, BreakingPointPoint, SimulationMetrics } from '../api/types'

const POINTS = [ 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0 ]

function metrics(p90: number, orders: number): SimulationMetrics {
  return {
    orders, drinks: orders * 2, station_utilisation: 0.7, reneged: 0, remakes: 5,
    wait_by_drink_cost: {
      cheap: { orders: 50, p90: 100 }, dear: { orders: 20, p90: 120 },
      comparable: true, ratio: 1.2,
    },
    eta_accuracy: { orders, capped: 0, measurable: true, p50_abs: 14.5, p90_abs: 44.2, bias: 2.4 },
    quality_breach_rate: 0.1, quality_breach_rate_multi: 0.2,
    wait_seconds: { p50: p90 / 2, p90, p99: p90 * 1.5 },
    by_size_class: {
      '1-2': { orders: orders / 2, p90_meaningful: true, p50: p90 / 2, p90, p99: p90 * 1.5 },
      '3-6': { orders: orders / 3, p90_meaningful: true, p50: p90 / 2, p90, p99: p90 * 1.5 },
      '7+': { orders: orders / 6, p90_meaningful: orders / 6 >= 10, p50: p90 / 2, p90, p99: p90 * 1.5 },
    },
  }
}

// Overall p90 rises with demand, crossing 900s (15 min) at 2.5x — mirrors
// what a busy shop actually looks like (§10.3's own table).
function point(demand: number, p90: number, orders: number): BreakingPointPoint {
  return { demand_multiplier: demand, arrived: Math.round(orders * 1.1), metrics: metrics(p90, orders) }
}

function result(overrides: Partial<BreakingPoint> = {}): BreakingPoint {
  return {
    seed: 7, seeds: 1, stations: 3, target_seconds: 900,
    points: [
      point(0.5, 120, 180), point(0.75, 180, 220), point(1.0, 240, 260),
      point(1.25, 320, 300), point(1.5, 420, 340), point(1.75, 540, 380),
      point(2.0, 660, 420), point(2.25, 780, 460), point(2.5, 960, 500),
      point(3.0, 1500, 580),
    ],
    capacity: 2.5,
    ...overrides,
  }
}

describe('BreakingPointChart (§10.5 #4)', () => {
  it('names the capacity it found', () => {
    render(<BreakingPointChart result={result()} />)

    expect(screen.getByText('Breaking point — capacity 2.5×')).toBeInTheDocument()
  })

  it('names the seed, day count, and stations, so the chart can be re-run', () => {
    render(<BreakingPointChart result={result({ seeds: 12, stations: 4 })} />)

    expect(screen.getByText(/seed 7/)).toBeInTheDocument()
    expect(screen.getByText(/12 days pooled/)).toBeInTheDocument()
    expect(screen.getByText(/4 stations/)).toBeInTheDocument()
  })

  it('marks the target line', () => {
    render(<BreakingPointChart result={result()} />)

    expect(screen.getByText('target 900s')).toBeInTheDocument()
  })

  it('marks the capacity line at the computed demand multiplier', () => {
    render(<BreakingPointChart result={result()} />)

    expect(screen.getByText('capacity 2.5×')).toBeInTheDocument()
  })

  // Regression: without these, a reader could only place a point's height by
  // hovering it — see `QuantumSweepChart`'s identical fix.
  it('labels the top and bottom reference line', () => {
    render(<BreakingPointChart result={result()} />)

    expect(screen.getByText('1500s')).toBeInTheDocument()
    expect(screen.getByText('120s')).toBeInTheDocument()
  })

  it('carries an exact figure for every point', () => {
    render(<BreakingPointChart result={result()} />)

    expect(screen.getAllByText(/demand — overall p90/)).toHaveLength(POINTS.length)
    expect(screen.getByText('0.5× demand — overall p90 120s (n=180)')).toBeInTheDocument()
    expect(screen.getByText('3× demand — overall p90 1500s (n=580)')).toBeInTheDocument()
  })

  it('names the range tried when capacity was never reached', () => {
    const unreached = result({
      capacity: null,
      points: result().points.map((p) => ({ ...p, metrics: metrics(300, p.metrics.orders) })),
    })

    render(<BreakingPointChart result={unreached} />)

    expect(screen.getByText('Breaking point — capacity beyond 3×')).toBeInTheDocument()
    expect(screen.getByText(/not reached anywhere in the swept range/i)).toBeInTheDocument()
  })

  it('stays quiet about the range when capacity was found', () => {
    render(<BreakingPointChart result={result()} />)

    expect(screen.queryByText(/not reached anywhere/i)).not.toBeInTheDocument()
  })

  it('warns that a single day cannot pin down the exact crossing', () => {
    render(<BreakingPointChart result={result()} />)

    expect(screen.getByText(/one day only/i)).toBeInTheDocument()
  })

  it('drops the warning once several days are pooled', () => {
    render(<BreakingPointChart result={result({ seeds: 12 })} />)

    expect(screen.queryByText(/one day only/i)).not.toBeInTheDocument()
  })
})

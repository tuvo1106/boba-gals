import { render, screen, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { QuantumSweepChart } from './QuantumSweepChart'
import type { QuantumSweep, QuantumSweepPoint, SimulationMetrics } from '../api/types'

const POINTS = [ 30, 45, 60, 90, 120, 150, 180, 240, 300, 400 ]

function metrics(small: number, large: number, largeOrders = 25): SimulationMetrics {
  return {
    orders: 400, drinks: 800, station_utilisation: 0.6, reneged: 0, remakes: 10,
    wait_by_drink_cost: {
      cheap: { orders: 200, p90: 100 }, dear: { orders: 40, p90: 120 },
      comparable: true, ratio: 1.2,
    },
    eta_accuracy: { orders: 400, capped: 0, measurable: true, p50_abs: 14.5, p90_abs: 44.2, bias: 2.4 },
    quality_breach_rate: 0.1, quality_breach_rate_multi: 0.2,
    wait_seconds: { p50: 60, p90: small, p99: 300 },
    by_size_class: {
      '1-2': { orders: 300, p90_meaningful: true, p50: 60, p90: small, p99: 200 },
      '3-6': { orders: 60, p90_meaningful: true, p50: 100, p90: 200, p99: 400 },
      '7+': { orders: largeOrders, p90_meaningful: largeOrders >= 10, p50: 300, p90: large, p99: 900 },
    },
  }
}

// Small rises and large falls across the sweep, mirroring what a run at 1.6×
// demand, seed 7, actually measures.
function point(quantum: number, small: number, large: number, largeOrders = 25): QuantumSweepPoint {
  return { quantum, arrived: 2994, metrics: metrics(small, large, largeOrders) }
}

function sweep(overrides: Partial<QuantumSweep> = {}): QuantumSweep {
  return {
    seed: 7, seeds: 1, stations: 3, demand_multiplier: 1.6,
    points: [
      point(30, 356, 1892), point(45, 344, 2008), point(60, 339, 1923),
      point(90, 321, 1994), point(120, 303, 1872), point(150, 323, 1898),
      point(180, 336, 1811), point(240, 392, 1535), point(300, 375, 1527),
      point(400, 418, 1523),
    ],
    ...overrides,
  }
}

describe('QuantumSweepChart (§10.5 #2)', () => {
  it('names the range it swept', () => {
    render(<QuantumSweepChart sweep={sweep()} />)

    expect(screen.getByText('Quantum sweep — 30s to 400s')).toBeInTheDocument()
  })

  it('names the seed and day count, so the chart can be re-run', () => {
    render(<QuantumSweepChart sweep={sweep({ seeds: 12 })} />)

    expect(screen.getByText(/seed 7/)).toBeInTheDocument()
    expect(screen.getByText(/12 days pooled/)).toBeInTheDocument()
  })

  it('marks the shipped default quantum', () => {
    render(<QuantumSweepChart sweep={sweep()} />)

    expect(screen.getByText('default 60s')).toBeInTheDocument()
  })

  it('labels both series in the legend', () => {
    render(<QuantumSweepChart sweep={sweep()} />)

    const legend = within(screen.getByRole('list'))
    expect(legend.getByText('1–2 drinks')).toBeInTheDocument()
    expect(legend.getByText('7+ drinks')).toBeInTheDocument()
  })

  // Every point on both series gets a tooltip with the exact figure — the
  // chart is drawn at a scale that cannot show it directly. `<title>` sits
  // inside each `<circle>` rather than directly under `<svg>`, so it is read
  // as ordinary text rather than through `getByTitle` (which only matches an
  // `<svg> > title` child).
  it('carries an exact figure for every point on both series', () => {
    render(<QuantumSweepChart sweep={sweep()} />)

    expect(screen.getAllByText(/1–2 drinks p90/)).toHaveLength(POINTS.length)
    expect(screen.getAllByText(/7\+ drinks p90/)).toHaveLength(POINTS.length)
    expect(screen.getByText('quantum 30s — 1–2 drinks p90 356s')).toBeInTheDocument()
    expect(screen.getByText('quantum 400s — 7+ drinks p90 1523s')).toBeInTheDocument()
  })

  // A p90 over a handful of orders is the maximum, not a percentile — same
  // caveat the ablation and single-run views carry.
  it('flags a point too thin to be a percentile', () => {
    const thin = sweep()
    thin.points[6] = point(180, 336, 1811, 4)

    render(<QuantumSweepChart sweep={thin} />)

    expect(screen.getByText('quantum 180s — 7+ drinks p90 1811s (n=4, not a percentile)')).toBeInTheDocument()
  })

  it('warns that a single day cannot separate a small gap from noise', () => {
    render(<QuantumSweepChart sweep={sweep()} />)

    expect(screen.getByText(/one day only/i)).toBeInTheDocument()
  })

  it('drops the warning once several days are pooled', () => {
    render(<QuantumSweepChart sweep={sweep({ seeds: 12 })} />)

    expect(screen.queryByText(/one day only/i)).not.toBeInTheDocument()
  })
})

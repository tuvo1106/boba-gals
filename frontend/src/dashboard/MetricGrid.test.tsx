import { render, screen, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { MetricGrid } from './MetricGrid'
import type { SimulationMetrics } from '../api/types'

function metrics(overrides: Partial<SimulationMetrics> = {}): SimulationMetrics {
  return {
    orders: 400, drinks: 800, station_utilisation: 0.6, reneged: 0, remakes: 10,
    wait_by_drink_cost: {
      cheap: { orders: 200, p90: 100 }, dear: { orders: 40, p90: 120 },
      comparable: true, ratio: 1.2,
    },
    eta_accuracy: {
      orders: 369, capped: 0, measurable: true, p50_abs: 14.5, p90_abs: 44.2, bias: 2.4,
    },
    quality_breach_rate: 0.1, quality_breach_rate_multi: 0.2,
    wait_seconds: { p50: 60, p90: 200, p99: 300 },
    by_size_class: {
      '1-2': { orders: 311, p90_meaningful: true, p50: 44, p90: 158, p99: 402 },
      '3-6': { orders: 47, p90_meaningful: true, p50: 96, p90: 240, p99: 501 },
      '7+': { orders: 4, p90_meaningful: false, p50: 208, p90: 520, p99: 520 },
    },
    ...overrides,
  }
}

describe('MetricGrid (§10.4)', () => {
  // "Report p50 / p90 / p99 — never the mean." All three, for all three
  // classes: the figure row above this one renders two of the nine.
  it('shows every percentile for every size class', () => {
    render(<MetricGrid metrics={metrics()} />)

    const middle = screen.getByRole('row', { name: /3–6 drinks/ })

    expect(within(middle).getByText('96s')).toBeInTheDocument()
    expect(within(middle).getByText('240s')).toBeInTheDocument()
    expect(within(middle).getByText('501s')).toBeInTheDocument()
  })

  // The class the dashboard has never rendered. A scheduler starving the middle
  // was invisible on this screen.
  it('shows the middle class, not just the two the headline uses', () => {
    render(<MetricGrid metrics={metrics()} />)

    expect(screen.getByRole('row', { name: /1–2 drinks/ })).toBeInTheDocument()
    expect(screen.getByRole('row', { name: /3–6 drinks/ })).toBeInTheDocument()
    expect(screen.getByRole('row', { name: /7\+ drinks/ })).toBeInTheDocument()
  })

  it('carries the order count beside the figures', () => {
    render(<MetricGrid metrics={metrics()} />)

    expect(within(screen.getByRole('row', { name: /1–2 drinks/ })).getByText('311')).toBeInTheDocument()
  })

  // A p90 over four orders is the maximum, not a percentile.
  it('flags a class too thin to support a percentile', () => {
    render(<MetricGrid metrics={metrics()} />)

    const thin = screen.getByRole('row', { name: /7\+ drinks/ })
    const fat = screen.getByRole('row', { name: /1–2 drinks/ })

    expect(within(thin).getByTitle(/too few orders/i)).toBeInTheDocument()
    expect(within(fat).queryByTitle(/too few orders/i)).not.toBeInTheDocument()
  })

  describe('the ETA row (§10.4, §7.3)', () => {
    // Scoped to each figure: "44s" is also the 1–2 class's p50 further up the
    // page, and a bare text query would pass on the wrong number.
    function figure(label: string) {
      return screen.getByText(label).parentElement as HTMLElement
    }

    it('reports absolute error and bias, which answer different questions', () => {
      render(<MetricGrid metrics={metrics()} />)

      expect(within(figure('typical miss')).getByText('15s')).toBeInTheDocument()
      expect(within(figure('worst 10%')).getByText('44s')).toBeInTheDocument()
      expect(within(figure('bias')).getByText('+2s')).toBeInTheDocument()
    })

    // Signed, and the sign is the whole point: late is the direction that costs
    // trust. An unsigned bias would read identically for a shop that is always
    // early and one that is always late.
    it('signs the bias so late and early cannot read alike', () => {
      render(<MetricGrid metrics={metrics()} />)

      expect(screen.getByText('+2s')).toBeInTheDocument()
    })

    it('says the shop beat its quote when the bias is negative', () => {
      const early = metrics()
      early.eta_accuracy = { ...early.eta_accuracy, bias: -231.6 }

      render(<MetricGrid metrics={early} />)

      expect(screen.getByTitle(/ready .* earlier than it said/)).toBeInTheDocument()
    })

    it('says the shop ran late when the bias is positive', () => {
      const late = metrics()
      late.eta_accuracy = { ...late.eta_accuracy, bias: 300 }

      render(<MetricGrid metrics={late} />)

      expect(screen.getByTitle(/ready .* later than it said/)).toBeInTheDocument()
    })

    // A capped quote is a floor, so its error would measure the cap. Counted on
    // screen rather than silently dropped — many of them means the figures
    // describe only the minority who got a real answer.
    it('discloses quotes that hit the projection horizon', () => {
      const swamped = metrics()
      swamped.eta_accuracy = { ...swamped.eta_accuracy, capped: 398 }

      render(<MetricGrid metrics={swamped} />)

      expect(screen.getByText(/398 orders queued past the hour/)).toBeInTheDocument()
    })

    it('says nothing about capping when nothing was capped', () => {
      render(<MetricGrid metrics={metrics()} />)

      expect(screen.queryByText(/queued past the hour/)).not.toBeInTheDocument()
    })

    it('flags an error figure computed over too few orders', () => {
      const thin = metrics()
      thin.eta_accuracy = { ...thin.eta_accuracy, orders: 3, measurable: false }

      render(<MetricGrid metrics={thin} />)

      expect(screen.getByTitle(/too few to be a percentile/)).toBeInTheDocument()
    })

    it('says so rather than showing zeros when nothing completed', () => {
      const empty = metrics()
      empty.eta_accuracy = { orders: 0, capped: 0, measurable: false, p50_abs: 0, p90_abs: 0, bias: 0 }

      render(<MetricGrid metrics={empty} />)

      expect(screen.getByText(/no completed orders to score/i)).toBeInTheDocument()
    })
  })
})

import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { AblationBars } from './AblationBars'
import type { Ablation, AblationArm, SimulationMetrics } from '../api/types'

function metrics(
  small: number, large: number, cheap = 100, dear = 120,
): SimulationMetrics {
  return {
    orders: 400, drinks: 800, station_utilisation: 0.6, reneged: 0, remakes: 10,
    wait_by_drink_cost: {
      cheap: { orders: 200, p90: cheap }, dear: { orders: 40, p90: dear },
      comparable: true, ratio: dear / cheap,
    },
    quality_breach_rate: 0.1, quality_breach_rate_multi: 0.2,
    wait_seconds: { p50: 60, p90: small, p99: 300 },
    by_size_class: {
      '1-2': { orders: 300, p90_meaningful: true, p50: 60, p90: small, p99: 200 },
      '3-6': { orders: 60, p90_meaningful: true, p50: 100, p90: 200, p99: 400 },
      '7+': { orders: 25, p90_meaningful: true, p50: 300, p90: large, p99: 900 },
    },
  }
}

function arm(
  id: string, kind: AblationArm['kind'], label: string,
  small: number, large: number, cheap?: number, dear?: number,
): AblationArm {
  return {
    id, kind, label, blurb: `${label} explained`, arrived: 603,
    metrics: metrics(small, large, cheap, dear),
  }
}

function ablation(overrides: Partial<Ablation> = {}): Ablation {
  return {
    seed: 7, seeds: 1, stations: 3, demand_multiplier: 1.6, quantum: null,
    arms: [
      arm('fifo', 'control', 'First come, first served', 690, 952, 540, 594),
      arm('rr', 'rung', 'Round robin', 266, 2255, 177, 148),
      arm('drr', 'rung', '+ the deficit', 350, 2777, 136, 298),
      arm('drr_aging', 'rung', '+ aging', 379, 2126, 196, 350),
      arm('drr_aging_cohesion', 'rung', '+ cohesion', 380, 1899, 187, 317),
      arm('sjf', 'bound', 'Shortest job first', 304, 1604, 82, 947),
    ],
    ...overrides,
  }
}

describe('AblationBars (§10.5)', () => {
  it('shows every arm', () => {
    render(<AblationBars ablation={ablation()} />)

    expect(screen.getByText('First come, first served')).toBeInTheDocument()
    expect(screen.getByText('Round robin')).toBeInTheDocument()
    expect(screen.getByText('+ cohesion')).toBeInTheDocument()
    expect(screen.getByText('Shortest job first')).toBeInTheDocument()
  })

  // The claim is about how the two halves move *relative to each other*. A
  // chart showing only the flattering half would make SJF look like the best
  // scheduler ever written (§10.4).
  it('shows both halves for every arm, never just the flattering one', () => {
    render(<AblationBars ablation={ablation()} />)

    expect(screen.getAllByLabelText(/1–2 drinks p90/)).toHaveLength(6)
    expect(screen.getAllByLabelText(/7\+ drinks p90/)).toHaveLength(6)
  })

  // Scaling each series to its own maximum would draw a 2777s bar the same
  // length as a 350s one and silently delete the comparison.
  it('draws both halves against one shared scale', () => {
    render(<AblationBars ablation={ablation()} />)

    const widthOf = (label: string) => screen.getByLabelText(label).style.width

    // 2777 is the worst value anywhere, so it is the full-width bar.
    expect(widthOf('7+ drinks p90 2777.0s')).toBe('100%')
    // 350/2777 ≈ 12.6%, not the ~50% it would be on a per-series scale.
    expect(parseFloat(widthOf('1–2 drinks p90 350.0s'))).toBeCloseTo(12.6, 0)
  })

  it('names the seed and the day count, so the chart can be re-run', () => {
    render(<AblationBars ablation={ablation({ seeds: 12 })} />)

    expect(screen.getByText(/seed 7/)).toBeInTheDocument()
    expect(screen.getByText(/12 days pooled/)).toBeInTheDocument()
  })

  // The property that makes it an experiment: same customers in every arm.
  it('says the arms saw the same customers', () => {
    render(<AblationBars ablation={ablation()} />)

    expect(screen.getByText(/603 customers, same in every arm/)).toBeInTheDocument()
  })

  // Measured: the cohesion arm's spread moved −5.5%, +1.5% and +3.7% across
  // three demand levels at twelve seeds each. A single day cannot separate a
  // real effect from that, and a bar chart invites exactly that reading.
  it('warns that a single day cannot separate a small gap from noise', () => {
    render(<AblationBars ablation={ablation()} />)

    expect(screen.getByText(/small differences here are noise/i)).toBeInTheDocument()
  })

  it('drops the warning once several days are pooled', () => {
    render(<AblationBars ablation={ablation({ seeds: 12 })} />)

    expect(screen.queryByText(/small differences here are noise/i)).not.toBeInTheDocument()
  })

  it('reads each arm against the control, which is what an ablation is for', () => {
    render(<AblationBars ablation={ablation()} />)

    // DRR's 350 against FIFO's 690 — very nearly halved.
    const gains = screen.getAllByTitle(/1–2 drinks p90 against the/)
    expect(gains.map((node) => node.textContent)).toContain('-49%')
  })

  // A lone green "-49%" is true and is exactly the misreading the chart exists
  // to prevent. The number beside it is what that improvement cost.
  it('shows what each improvement cost, next to the improvement', () => {
    render(<AblationBars ablation={ablation()} />)

    // DRR's 2777 against FIFO's 952 — nearly tripled, and it must be on screen.
    const costs = screen.getAllByTitle(/7\+ drinks p90 against the/)
    expect(costs.map((node) => node.textContent)).toContain('+192%')
  })

  // A p90 over a handful of orders is the maximum, not a percentile — the same
  // caveat the single-run grid carries.
  it('flags a figure that is too thin to be a percentile', () => {
    const thin = ablation()
    thin.arms[2].metrics.by_size_class['7+'] = {
      orders: 3, p90_meaningful: false, p50: 300, p90: 2777, p99: 900,
    }

    render(<AblationBars ablation={thin} />)

    expect(screen.getByText('n=3')).toBeInTheDocument()
  })

  // §6.3's two comparison arms are not separable on order size. Measured, SJF's
  // 7+ p90 *beats* DRR's, because §2 makes the job a drink rather than an order
  // — so SJF serves a catering order of cheap drinks happily. Without this axis
  // the chart argues against the design.
  describe('the drink-cost axis (§6.1)', () => {
    it('starts on order size, which is what §10.5 #1 asks for', () => {
      render(<AblationBars ablation={ablation()} />)

      expect(screen.getByRole('button', { name: /by order size/i })).toHaveAttribute('aria-pressed', 'true')
      expect(screen.getAllByLabelText(/1–2 drinks p90/)).toHaveLength(6)
    })

    it('switches every arm to cheap against dear drinks', async () => {
      const user = userEvent.setup()
      render(<AblationBars ablation={ablation()} />)

      await user.click(screen.getByRole('button', { name: /by drink cost/i }))

      expect(screen.getAllByLabelText(/simple drinks p90/)).toHaveLength(6)
      expect(screen.getAllByLabelText(/topping-heavy p90/)).toHaveLength(6)
      expect(screen.queryByLabelText(/1–2 drinks p90/)).not.toBeInTheDocument()
    })

    // The whole reason the toggle exists: SJF's 947s topping-heavy bar is the
    // longest thing on the chart, and it is invisible on the size axis.
    it('rescales to the new axis rather than keeping the old maximum', async () => {
      const user = userEvent.setup()
      render(<AblationBars ablation={ablation()} />)

      await user.click(screen.getByRole('button', { name: /by drink cost/i }))

      expect(screen.getByLabelText('topping-heavy p90 947.0s').style.width).toBe('100%')
    })
  })

  // SJF is not selectable on a store — `UpdateSchedulerConfig` rejects it
  // (§6.3). Drawn inline it reads as a candidate that happens to win, which on
  // the size axis it genuinely does.
  it('sets the bound apart from the ladder, so it does not read as a candidate', () => {
    render(<AblationBars ablation={ablation()} />)

    expect(screen.getByText(/not a policy/i)).toBeInTheDocument()
  })

  it('draws no bound section when every arm is one', () => {
    const ladderOnly = ablation()
    ladderOnly.arms = ladderOnly.arms.filter((a) => a.kind !== 'bound')

    render(<AblationBars ablation={ladderOnly} />)

    expect(screen.queryByText(/not a policy/i)).not.toBeInTheDocument()
  })
})

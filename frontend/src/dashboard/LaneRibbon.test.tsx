import { render, screen, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { LaneRibbon } from './LaneRibbon'
import type { TimelineDrink } from '../api/types'

function drink(overrides: Partial<TimelineDrink> = {}): TimelineDrink {
  return {
    order_id: 1, drink_id: '1-0', station: 0,
    started_at: 0, finished_at: 60, prep_seconds: 60,
    remake: false, order_size: 1,
    ...overrides,
  }
}

describe('LaneRibbon', () => {
  it('renders one lane per station', () => {
    render(<LaneRibbon drinks={[]} stations={3} from={0} to={600} />)

    expect(screen.getAllByRole('row')).toHaveLength(3)
  })

  it('places each drink on its own station', () => {
    render(
      <LaneRibbon
        drinks={[ drink({ station: 0, drink_id: 'a' }), drink({ station: 2, drink_id: 'b' }) ]}
        stations={3} from={0} to={600}
      />,
    )

    expect(within(screen.getByRole('row', { name: 'Station 1' })).getByTitle(/Order 1/)).toBeInTheDocument()
    expect(within(screen.getByRole('row', { name: 'Station 3' })).getByTitle(/Order 1/)).toBeInTheDocument()
    expect(within(screen.getByRole('row', { name: 'Station 2' })).queryByTitle(/Order/)).not.toBeInTheDocument()
  })

  // Colour is identity: the eye groups one hue into "that order", which is how
  // interleaving becomes visible at all (§10.6).
  it('gives every order a distinct, stable colour', () => {
    const { container } = render(
      <LaneRibbon
        drinks={[ drink({ order_id: 1, drink_id: 'a' }), drink({ order_id: 2, drink_id: 'b' }), drink({ order_id: 1, drink_id: 'c' }) ]}
        stations={1} from={0} to={600}
      />,
    )

    const colours = Array.from(container.querySelectorAll('[title]')).map(
      (el) => (el as HTMLElement).style.background,
    )

    expect(colours[0]).toBe(colours[2])
    expect(colours[0]).not.toBe(colours[1])
  })

  it('positions a capsule by when it ran', () => {
    const { container } = render(
      <LaneRibbon drinks={[ drink({ started_at: 300, finished_at: 360 }) ]} stations={1} from={0} to={600} />,
    )

    const capsule = container.querySelector('[title]') as HTMLElement

    expect(capsule.style.left).toBe('50%')
    expect(capsule.style.width).toContain('10%')
  })

  // A sub-pixel capsule vanishes, and a drink that ran should always be visible.
  it('keeps a very short drink visible', () => {
    const { container } = render(
      <LaneRibbon drinks={[ drink({ started_at: 0, finished_at: 1 }) ]} stations={1} from={0} to={36000} />,
    )

    expect((container.querySelector('[title]') as HTMLElement).style.width).toContain('2px')
  })

  it('marks remakes distinctly, so the priority floor is visible (§9.4)', () => {
    const { container } = render(
      <LaneRibbon drinks={[ drink({ remake: true }) ]} stations={1} from={0} to={600} />,
    )

    expect(container.querySelector('.border-dashed')).toBeInTheDocument()
    expect(screen.getByTitle(/remake/)).toBeInTheDocument()
  })

  it('labels a drink with its order size, so large orders are identifiable', () => {
    render(<LaneRibbon drinks={[ drink({ order_size: 12 }) ]} stations={1} from={0} to={600} />)

    expect(screen.getByTitle(/12 drinks/)).toBeInTheDocument()
  })

  it('renders a clock axis in shop time, not simulated seconds', () => {
    render(<LaneRibbon drinks={[]} stations={1} from={0} to={7200} />)

    expect(screen.getByText('10:00')).toBeInTheDocument()
    expect(screen.getByText('12:00')).toBeInTheDocument()
  })

  it('renders an unfinished drink to the end of the window', () => {
    const { container } = render(
      <LaneRibbon drinks={[ drink({ started_at: 300, finished_at: null }) ]} stations={1} from={0} to={600} />,
    )

    expect((container.querySelector('[title]') as HTMLElement).style.width).toContain('50%')
  })
})

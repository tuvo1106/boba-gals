import { useState } from 'react'
import type { Ablation, AblationArm } from '../api/types'

/** Seconds, as the panel writes every other duration. */
function secs(value: number): string {
  return `${value.toFixed(1)}s`
}

/**
 * The two questions the arms are judged on. One chart cannot answer both, and
 * answering only the first is how SJF gets read as the winner.
 *
 * - `size` — §10.4's size classes. Does a big order block a small one? This is
 *   what §6.1 and §10.5 #1 are about, and it is the default.
 * - `cost` — §6.1's other question: "does your wait depend on what you
 *   ordered?" Small orders only, split by how expensive their drinks are, so
 *   order size is held fixed and drink cost is the only thing varying.
 */
type Axis = 'size' | 'cost'

interface Series {
  label: string
  /** The longer/worse-off half, drawn second and muted. */
  other: string
  read: (arm: AblationArm) => [ Row, Row ]
  caption: string
}

interface Row {
  p90: number
  meaningful: boolean
  orders: number
}

const AXES: Record<Axis, Series> = {
  size: {
    label: '1–2 drinks',
    other: '7+ drinks',
    caption: 'does a catering order block the person behind it?',
    read: (arm) => {
      const by = arm.metrics.by_size_class
      return [
        { p90: by['1-2'].p90, meaningful: by['1-2'].p90_meaningful, orders: by['1-2'].orders },
        { p90: by['7+'].p90, meaningful: by['7+'].p90_meaningful, orders: by['7+'].orders },
      ]
    },
  },
  cost: {
    label: 'simple drinks',
    other: 'topping-heavy',
    caption: 'small orders only — does your wait depend on what you ordered? (§6.1)',
    read: (arm) => {
      const { cheap, dear, comparable } = arm.metrics.wait_by_drink_cost
      return [
        { p90: cheap.p90, meaningful: comparable, orders: cheap.orders },
        { p90: dear.p90, meaningful: comparable, orders: dear.orders },
      ]
    },
  },
}

/**
 * §10.5's first experiment, rendered: "Four bars, one chart. This is the proof
 * the design works."
 *
 * Two series per arm, not one. A single bar showing the flattering half would
 * make SJF look like the best scheduler ever written — the whole claim is about
 * how the two halves move *relative to each other*, so the chart that omits the
 * cost is the chart that proves the wrong thing (§10.4).
 *
 * **And two axes, not one.** §6.3's comparison arms are not separable on order
 * size. ADR-0013 measured it and this reproduces it: SJF's 7+ p90 *beats* DRR's,
 * because §2 makes the job a drink rather than an order, so SJF happily serves a
 * catering order of cheap drinks. Its damage lands on drink cost instead — a
 * dear/cheap p90 ratio of 38 at 2.2× demand against DRR's 2.0. On the size axis
 * alone, adding SJF to this chart would argue against the design rather than
 * for it.
 *
 * Bars are scaled against the worst value across both series, so the two halves
 * share an axis and can be compared by eye. Scaling each series to its own
 * maximum would draw the long bars at the same length as the short ones and
 * quietly delete the comparison.
 */
export function AblationBars({ ablation }: { ablation: Ablation }) {
  const [ axis, setAxis ] = useState<Axis>('size')
  const series = AXES[axis]

  const arms = ablation.arms
  const rows = arms.map((arm) => ({ arm, pair: series.read(arm) }))
  const worst = Math.max(...rows.flatMap(({ pair }) => [ pair[0].p90, pair[1].p90 ]), 1)

  const baseline = rows.find(({ arm }) => arm.kind === 'control')
  const ladder = rows.filter(({ arm }) => arm.kind !== 'bound')
  const bounds = rows.filter(({ arm }) => arm.kind === 'bound')

  return (
    <section className="mt-8 border-t border-neutral-800 pt-4">
      <header className="mb-3 flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <h2 className="font-mono text-xs tracking-widest text-neutral-500 uppercase">
          One day, scheduled {arms.length} ways
        </h2>
        {/* Same seed for every arm, so a difference is the mechanism and not a
            luckier day. Stated on the chart because it is the only thing that
            makes the comparison mean anything (ADR-0011). */}
        <p className="font-mono text-xs text-neutral-600">
          seed {ablation.seed} · {ablation.seeds === 1 ? 'one day' : `${ablation.seeds} days pooled`} ·{' '}
          {ablation.stations} stations · {ablation.demand_multiplier}× demand ·{' '}
          <span title="Identical in every arm — that is what makes this an experiment rather than several unrelated runs.">
            {arms[0]?.arrived.toLocaleString()} customers, same in every arm
          </span>
        </p>
      </header>

      <div className="mb-3 flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <div className="flex gap-1" role="group" aria-label="Compare arms by">
          {(Object.keys(AXES) as Axis[]).map((key) => (
            <button
              key={key}
              type="button"
              onClick={() => setAxis(key)}
              aria-pressed={axis === key}
              className={`border px-2 py-0.5 font-mono text-[10px] tracking-wide uppercase ${
                axis === key
                  ? 'border-amber-700 bg-amber-950 text-amber-300'
                  : 'border-neutral-800 text-neutral-500 hover:border-neutral-700 hover:text-neutral-300'
              }`}
            >
              by {key === 'size' ? 'order size' : 'drink cost'}
            </button>
          ))}
        </div>
        <p className="font-mono text-xs text-neutral-600">{series.caption}</p>
      </div>

      {/* One seed is one Tuesday. The arms differ by a few percent on a quiet
          day, which is inside the noise — measured, the cohesion arm's spread
          moved −5.5%, +1.5% and +3.7% at three demand levels on twelve seeds
          each. Saying so on the chart is cheaper than someone reading a
          twelve-percent bar as a result. */}
      {ablation.seeds === 1 && (
        <p className="mb-3 border-l-2 border-neutral-700 pl-3 font-mono text-xs text-neutral-500">
          One day only — small differences here are noise. Raise the day count before believing a
          gap under about 10%.
        </p>
      )}

      <div className="flex flex-col gap-3">
        {ladder.map((row) => (
          <ArmRow key={row.arm.id} row={row} baseline={baseline} series={series} worst={worst} />
        ))}
      </div>

      {bounds.length > 0 && (
        <div className="mt-5 border-t border-dashed border-neutral-800 pt-4">
          {/* Set apart deliberately. SJF is not a rung on the ladder and is not
              selectable on a store (§6.3) — `UpdateSchedulerConfig` rejects it.
              Drawn inline with the others it reads as a candidate that happens
              to win, which on the size axis it does. */}
          <p className="mb-2 font-mono text-[10px] tracking-wide text-neutral-600 uppercase">
            not a policy — the bound DRR is paying against (§6.3)
          </p>
          <div className="flex flex-col gap-3">
            {bounds.map((row) => (
              <ArmRow key={row.arm.id} row={row} baseline={baseline} series={series} worst={worst} />
            ))}
          </div>
        </div>
      )}

      <p className="mt-3 font-mono text-[10px] text-neutral-600">
        bars are the wait 9 in 10 customers stayed under · both halves share one scale
      </p>
    </section>
  )
}

function ArmRow({
  row, baseline, series, worst,
}: {
  row: { arm: AblationArm; pair: [ Row, Row ] }
  baseline: { arm: AblationArm; pair: [ Row, Row ] } | undefined
  series: Series
  worst: number
}) {
  const { arm, pair } = row
  const isControl = arm.id === baseline?.arm.id

  return (
    <div className="grid grid-cols-[13rem_1fr] items-center gap-x-4 gap-y-1">
      <div className="text-right">
        <p className="font-mono text-xs text-neutral-300" title={arm.blurb}>{arm.label}</p>
        {/* Both halves, never just the flattering one. A lone green "-56% vs
            control" against SJF is true and is the misreading the whole chart
            exists to prevent — the number beside it is what it cost. */}
        {!isControl && baseline && (
          <p className="font-mono text-[10px] tabular-nums text-neutral-600">
            <Delta value={pair[0].p90} against={baseline.pair[0].p90} label={series.label} />
            {' / '}
            <Delta value={pair[1].p90} against={baseline.pair[1].p90} label={series.other} />
            <span className="ml-1 text-neutral-700">vs control</span>
          </p>
        )}
      </div>

      <div className="flex flex-col gap-1">
        <Bar label={series.label} row={pair[0]} worst={worst} tone="accent" />
        <Bar label={series.other} row={pair[1]} worst={worst} tone="muted" />
      </div>
    </div>
  )
}

function Delta({ value, against, label }: { value: number; against: number; label: string }) {
  const change = against === 0 ? 0 : (value - against) / against

  return (
    <span
      className={change < 0 ? 'text-emerald-500' : 'text-amber-600'}
      title={`${label} p90 against the first-come-first-served control`}
    >
      {change < 0 ? '' : '+'}{(change * 100).toFixed(0)}%
    </span>
  )
}

function Bar({
  label, row, worst, tone,
}: {
  label: string
  row: Row
  worst: number
  tone: 'accent' | 'muted'
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="w-24 shrink-0 font-mono text-[10px] text-neutral-600">{label}</span>
      <div className="h-4 flex-1 bg-neutral-900">
        <div
          className={`h-full ${tone === 'accent' ? 'bg-amber-600' : 'bg-neutral-600'}`}
          style={{ width: `${Math.max((row.p90 / worst) * 100, 0.5)}%` }}
          role="img"
          aria-label={`${label} p90 ${secs(row.p90)}`}
        />
      </div>
      <span className="w-32 shrink-0 font-mono text-xs tabular-nums text-neutral-400">
        {secs(row.p90)}
        {/* A p90 over five orders is the maximum, not a percentile. The figure
            still shows, with the count that makes it readable — hiding it would
            leave a gap nobody could explain. */}
        {!row.meaningful && (
          <span className="ml-1 text-[10px] text-neutral-600" title={`only ${row.orders} orders — this is the slowest, not a percentile`}>
            n={row.orders}
          </span>
        )}
      </span>
    </div>
  )
}

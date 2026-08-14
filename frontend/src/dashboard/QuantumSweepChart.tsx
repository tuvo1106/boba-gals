import type { QuantumSweep } from '../api/types'

function secs(value: number): string {
  return `${value.toFixed(0)}s`
}

interface SeriesPoint {
  quantum: number
  p90: number
  meaningful: boolean
  orders: number
}

const WIDTH = 720
const HEIGHT = 200
const PAD_LEFT = 8
const PAD_RIGHT = 8
const PAD_TOP = 20
const PAD_BOTTOM = 24
const PLOT_W = WIDTH - PAD_LEFT - PAD_RIGHT
const PLOT_H = HEIGHT - PAD_TOP - PAD_BOTTOM

/** §6.6's shipped default (`DeficitScheduler::Config::DEFAULTS[:quantum]`) — the
 *  reference every other point on the sweep is read against. */
const DEFAULT_QUANTUM = 60

function xFor(quantum: number, [min, max]: [number, number]): number {
  if (max === min) return PAD_LEFT + PLOT_W / 2

  return PAD_LEFT + ((quantum - min) / (max - min)) * PLOT_W
}

/**
 * Each series scaled to its own range, not a shared one.
 *
 * Small-order and large-order p90 differ by roughly 5x under this design's
 * demand model (§10.3) — a catering order is more drinks, so its wait is
 * expected to be higher. Sharing one axis would flatten the small-order line
 * to near-zero and hide the one trade this chart exists to show: what a
 * bigger quantum costs one class against what it saves the other, each
 * measured against its own range.
 */
function yFor(value: number, [min, max]: [number, number]): number {
  if (max === min) return PAD_TOP + PLOT_H / 2

  const t = (value - min) / (max - min)

  return PAD_TOP + (1 - t) * PLOT_H
}

/** Top, middle, and bottom of the plot area — enough to read the shape of a
 *  ten-point sweep without crowding two independently-scaled axes. */
const GRID_FRACTIONS = [ 0, 0.5, 1 ]

/** The value at a fraction down from the top of a range — the inverse of the
 *  `yFor` calculation above, so a gridline's label matches where it's drawn. */
function valueAt(fraction: number, [min, max]: [number, number]): number {
  return max - fraction * (max - min)
}

function seriesFrom(sweep: QuantumSweep, sizeClass: '1-2' | '7+'): SeriesPoint[] {
  return sweep.points.map((p) => {
    const row = p.metrics.by_size_class[sizeClass]

    return { quantum: p.quantum, p90: row.p90, meaningful: row.p90_meaningful, orders: row.orders }
  })
}

function range(values: number[]): [number, number] {
  return [ Math.min(...values), Math.max(...values) ]
}

function path(points: SeriesPoint[], quantumRange: [number, number], valueRange: [number, number]): string {
  return points.map((p) => `${xFor(p.quantum, quantumRange)},${yFor(p.p90, valueRange)}`).join(' ')
}

/**
 * §10.5 #2, rendered: "Quantum sweep: 30s → 400s, plot small-order p90 and
 * large-order p90 together. The crossover is your setting."
 *
 * Ten points (`Simulator::QuantumSweep::POINTS`), the same day run at each,
 * so a difference between two points is the quantum and not a luckier
 * Tuesday (ADR-0011) — the same property `AblationBars` leans on.
 *
 * Two lines, each on its own scale (see `yFor`), against one shared x-axis.
 * Reading the crossover means watching where the amber line's *relative*
 * position starts rising faster than the grey line's is falling — this
 * chart does not compute that point for you, because doing so would invent
 * a false precision on top of ten noisy samples. What it gives instead is
 * both curves, at the same quantum, so the eye can do that.
 */
export function QuantumSweepChart({ sweep }: { sweep: QuantumSweep }) {
  const small = seriesFrom(sweep, '1-2')
  const large = seriesFrom(sweep, '7+')

  const quantumRange = range(sweep.points.map((p) => p.quantum))
  const smallRange = range(small.map((p) => p.p90))
  const largeRange = range(large.map((p) => p.p90))

  const defaultX = xFor(DEFAULT_QUANTUM, quantumRange)
  const axisY = HEIGHT - PAD_BOTTOM

  return (
    <section className="mt-8 border-t border-neutral-800 pt-4">
      <header className="mb-3 flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <h2 className="font-mono text-xs tracking-widest text-neutral-500 uppercase">
          Quantum sweep — {quantumRange[0]}s to {quantumRange[1]}s
        </h2>
        <p className="font-mono text-xs text-neutral-600">
          seed {sweep.seed} · {sweep.seeds === 1 ? 'one day' : `${sweep.seeds} days pooled`} ·{' '}
          {sweep.stations} stations · {sweep.demand_multiplier}× demand
        </p>
      </header>

      <p className="mb-2 font-mono text-xs text-neutral-600">
        <span className="text-amber-500">1–2 drinks</span> ({secs(smallRange[0])}–{secs(smallRange[1])}) against{' '}
        <span className="text-neutral-400">7+ drinks</span> ({secs(largeRange[0])}–{secs(largeRange[1])}) — each
        scaled to its own range, so both are readable on one chart.
      </p>

      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`} className="w-full text-neutral-600"
        role="img" aria-label="Small-order and large-order p90 wait plotted against the quantum, each on its own scale"
      >
        <line
          x1={defaultX} x2={defaultX} y1={PAD_TOP} y2={axisY}
          stroke="currentColor" strokeDasharray="2,3" className="text-neutral-800"
        />
        <text x={defaultX} y={PAD_TOP - 6} textAnchor="middle" className="fill-neutral-600" fontSize={9}>
          default {DEFAULT_QUANTUM}s
        </text>

        <line x1={PAD_LEFT} x2={WIDTH - PAD_RIGHT} y1={axisY} y2={axisY} stroke="currentColor" className="text-neutral-800" />

        {/* Three reference lines, each labelled on both scales at once — the
            caption above states the endpoints in words, this is what lets a
            reader place a point's *height* without hovering it. Top label sits
            below its line (the space above is the default-quantum marker's);
            the rest sit above theirs. */}
        {GRID_FRACTIONS.map((f) => {
          const y = PAD_TOP + f * PLOT_H

          return (
            <g key={f}>
              {f !== 1 && (
                <line
                  x1={PAD_LEFT} x2={WIDTH - PAD_RIGHT} y1={y} y2={y}
                  stroke="currentColor" strokeDasharray="1,3" className="text-neutral-900"
                />
              )}
              <text x={PAD_LEFT} y={f === 0 ? y + 10 : y - 3} textAnchor="start" className="fill-amber-500/70 tabular-nums" fontSize={8}>
                {secs(valueAt(f, smallRange))}
              </text>
              <text x={WIDTH - PAD_RIGHT} y={f === 0 ? y + 10 : y - 3} textAnchor="end" className="fill-neutral-500 tabular-nums" fontSize={8}>
                {secs(valueAt(f, largeRange))}
              </text>
            </g>
          )
        })}

        {sweep.points.map((p) => (
          <text
            key={p.quantum} x={xFor(p.quantum, quantumRange)} y={axisY + 14}
            textAnchor="middle" className="fill-neutral-600 tabular-nums" fontSize={9}
          >
            {p.quantum}
          </text>
        ))}

        <polyline points={path(large, quantumRange, largeRange)} fill="none" stroke="currentColor" strokeWidth={1.5} strokeDasharray="4,3" className="text-neutral-400" />
        <polyline points={path(small, quantumRange, smallRange)} fill="none" stroke="currentColor" strokeWidth={1.5} className="text-amber-500" />

        {large.map((p) => (
          <circle key={`large-${p.quantum}`} cx={xFor(p.quantum, quantumRange)} cy={yFor(p.p90, largeRange)} r={p.meaningful ? 2.5 : 1.5} className="fill-neutral-400">
            <title>
              {`quantum ${p.quantum}s — 7+ drinks p90 ${secs(p.p90)}`}
              {!p.meaningful && ` (n=${p.orders}, not a percentile)`}
            </title>
          </circle>
        ))}
        {small.map((p) => (
          <circle key={`small-${p.quantum}`} cx={xFor(p.quantum, quantumRange)} cy={yFor(p.p90, smallRange)} r={p.meaningful ? 2.5 : 1.5} className="fill-amber-500">
            <title>
              {`quantum ${p.quantum}s — 1–2 drinks p90 ${secs(p.p90)}`}
              {!p.meaningful && ` (n=${p.orders}, not a percentile)`}
            </title>
          </circle>
        ))}
      </svg>

      <ul className="mt-2 flex gap-4 font-mono text-[10px] text-neutral-600">
        <li className="flex items-center gap-1.5">
          <span className="h-0.5 w-4 bg-amber-500" /> 1–2 drinks
        </li>
        <li className="flex items-center gap-1.5">
          <span className="h-0.5 w-4 border-t border-dashed border-neutral-400" /> 7+ drinks
        </li>
      </ul>

      {sweep.seeds === 1 && (
        <p className="mt-3 border-l-2 border-neutral-700 pl-3 font-mono text-xs text-neutral-500">
          One day only — the middle of the sweep is noisy. Raise the day count and trust the endpoints
          over any single point.
        </p>
      )}
    </section>
  )
}

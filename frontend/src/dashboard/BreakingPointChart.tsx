import type { BreakingPoint } from '../api/types'

function secs(value: number): string {
  return `${value.toFixed(0)}s`
}

function demandLabel(value: number): string {
  return `${value}×`
}

interface SeriesPoint {
  demand: number
  p90: number
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

function xFor(demand: number, [min, max]: [number, number]): number {
  if (max === min) return PAD_LEFT + PLOT_W / 2

  return PAD_LEFT + ((demand - min) / (max - min)) * PLOT_W
}

function yFor(value: number, [min, max]: [number, number]): number {
  if (max === min) return PAD_TOP + PLOT_H / 2

  const t = (value - min) / (max - min)

  return PAD_TOP + (1 - t) * PLOT_H
}

/** Top, middle, and bottom of the plot area — see `QuantumSweepChart`'s
 *  identical constant. One series here, so one label per line is enough. */
const GRID_FRACTIONS = [ 0, 0.5, 1 ]

/** The value at a fraction down from the top of a range — the inverse of the
 *  `yFor` calculation above, so a gridline's label matches where it's drawn. */
function valueAt(fraction: number, [min, max]: [number, number]): number {
  return max - fraction * (max - min)
}

function seriesFrom(result: BreakingPoint): SeriesPoint[] {
  return result.points.map((p) => ({
    demand: p.demand_multiplier,
    p90: p.metrics.wait_seconds.p90,
    orders: p.metrics.orders,
  }))
}

function range(values: number[]): [number, number] {
  return [ Math.min(...values), Math.max(...values) ]
}

function path(points: SeriesPoint[], demandRange: [number, number], valueRange: [number, number]): string {
  return points.map((p) => `${xFor(p.demand, demandRange)},${yFor(p.p90, valueRange)}`).join(' ')
}

/**
 * §10.5 #4, rendered: "raise the demand multiplier until p90 exceeds 15 min.
 * That number is the store's real capacity."
 *
 * Unlike `QuantumSweepChart`, which deliberately leaves the crossover for the
 * eye to find, this chart draws `capacity` — the server already computed it
 * (`Simulator::BreakingPoint#call`), because §10.5 #4 asks for a number, not
 * a shape to read. The curve is still shown in full: a single computed figure
 * with no supporting shape invites more trust than a sweep this noisy earns.
 *
 * One series on one scale (unlike the quantum sweep's two independently
 * scaled lines) — capacity is a single question, "does overall p90 clear the
 * target", not a trade between two classes of customer.
 */
export function BreakingPointChart({ result }: { result: BreakingPoint }) {
  const series = seriesFrom(result)
  const demandRange = range(series.map((p) => p.demand))
  const valueRange = range([ ...series.map((p) => p.p90), result.target_seconds ])

  const targetY = yFor(result.target_seconds, valueRange)
  const capacityX = result.capacity === null ? null : xFor(result.capacity, demandRange)
  const axisY = HEIGHT - PAD_BOTTOM

  return (
    <section className="mt-8 border-t border-neutral-800 pt-4">
      <header className="mb-3 flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <h2 className="font-mono text-xs tracking-widest text-neutral-500 uppercase">
          Breaking point — capacity{' '}
          {result.capacity === null ? `beyond ${demandLabel(demandRange[1])}` : demandLabel(result.capacity)}
        </h2>
        <p className="font-mono text-xs text-neutral-600">
          seed {result.seed} · {result.seeds === 1 ? 'one day' : `${result.seeds} days pooled`} ·{' '}
          {result.stations} stations · target p90 under {secs(result.target_seconds)}
        </p>
      </header>

      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`} className="w-full text-neutral-600"
        role="img" aria-label="Overall p90 wait plotted against the demand multiplier, against a target line"
      >
        <line
          x1={PAD_LEFT} x2={WIDTH - PAD_RIGHT} y1={targetY} y2={targetY}
          stroke="currentColor" strokeDasharray="2,3" className="text-neutral-800"
        />
        <text x={WIDTH - PAD_RIGHT} y={targetY - 4} textAnchor="end" className="fill-neutral-600" fontSize={9}>
          target {secs(result.target_seconds)}
        </text>

        {capacityX !== null && (
          <>
            <line
              x1={capacityX} x2={capacityX} y1={PAD_TOP} y2={axisY}
              stroke="currentColor" strokeDasharray="2,3" className="text-rose-700"
            />
            <text x={capacityX} y={PAD_TOP - 6} textAnchor="middle" className="fill-rose-500" fontSize={9}>
              capacity {demandLabel(result.capacity as number)}
            </text>
          </>
        )}

        <line x1={PAD_LEFT} x2={WIDTH - PAD_RIGHT} y1={axisY} y2={axisY} stroke="currentColor" className="text-neutral-800" />

        {/* Three reference lines so a point's height is readable without
            hovering it — left-anchored, so they don't collide with the
            target line's right-anchored label. */}
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
              <text x={PAD_LEFT} y={f === 0 ? y + 10 : y - 3} textAnchor="start" className="fill-neutral-500 tabular-nums" fontSize={8}>
                {secs(valueAt(f, valueRange))}
              </text>
            </g>
          )
        })}

        {series.map((p) => (
          <text
            key={p.demand} x={xFor(p.demand, demandRange)} y={axisY + 14}
            textAnchor="middle" className="fill-neutral-600 tabular-nums" fontSize={9}
          >
            {p.demand}
          </text>
        ))}

        <polyline points={path(series, demandRange, valueRange)} fill="none" stroke="currentColor" strokeWidth={1.5} className="text-amber-500" />

        {series.map((p) => (
          <circle
            key={p.demand} cx={xFor(p.demand, demandRange)} cy={yFor(p.p90, valueRange)} r={2.5}
            className={p.p90 > result.target_seconds ? 'fill-rose-500' : 'fill-amber-500'}
          >
            <title>{`${demandLabel(p.demand)} demand — overall p90 ${secs(p.p90)} (n=${p.orders})`}</title>
          </circle>
        ))}
      </svg>

      {result.capacity === null && (
        <p className="mt-3 border-l-2 border-amber-700 pl-3 font-mono text-xs text-amber-600">
          Not reached anywhere in the swept range — this config holds target at least up to{' '}
          {demandLabel(demandRange[1])}. Widen the range to find the real number.
        </p>
      )}

      {result.seeds === 1 && (
        <p className="mt-3 border-l-2 border-neutral-700 pl-3 font-mono text-xs text-neutral-500">
          One day only — the exact crossing point can move on noise. Raise the day count before
          treating this as a hard capacity.
        </p>
      )}

      <p className="mt-3 font-mono text-[10px] text-neutral-600">
        unlike the ablation and quantum sweep, points here do not share arrivals — a higher demand
        multiplier means more customers by construction (§10.1)
      </p>
    </section>
  )
}

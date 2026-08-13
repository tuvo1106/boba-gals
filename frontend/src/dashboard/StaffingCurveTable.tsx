import type { StaffingCurve, StaffingCurveHour } from '../api/types'

/** Mirrors `Simulator::StaffingCurve::STATIONS_TRIED` — the widest count ever
 *  tried, so the bar for an unachieved hour reads as "we maxed this out" and
 *  not as an arbitrary length. */
const MAX_STATIONS_TRIED = 8

function secs(value: number): string {
  return `${Math.round(value)}s`
}

function label(hour: number): string {
  return `${hour}:00`
}

/**
 * §10.5 #3, rendered: "for each hour, minimum stations holding p90 under
 * target. Output is an actual shift schedule."
 *
 * A table rather than a line chart — the output of this experiment *is* the
 * schedule, not a trend to eyeball, so the row an operator actually staffs
 * against should be legible on its own without reading a curve.
 *
 * Bar length is stations, not wait — the other two §10.5 charts already show
 * wait against a knob; this one's job is to answer "how many people", so that
 * is the dimension drawn largest.
 */
export function StaffingCurveTable({ curve }: { curve: StaffingCurve }) {
  const worst = Math.max(...curve.hours.map((h) => h.stations), 1)

  return (
    <section className="mt-8 border-t border-neutral-800 pt-4">
      <header className="mb-3 flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <h2 className="font-mono text-xs tracking-widest text-neutral-500 uppercase">
          Staffing curve — p90 under {secs(curve.target_seconds)}
        </h2>
        <p className="font-mono text-xs text-neutral-600">
          seed {curve.seed} · {curve.seeds === 1 ? 'one day' : `${curve.seeds} days pooled`} ·{' '}
          {curve.demand_multiplier}× demand · each hour run at 1–{MAX_STATIONS_TRIED} stations, whole day
        </p>
      </header>

      <div className="overflow-x-auto">
        <table className="w-full min-w-125 border-collapse font-mono text-xs">
          <thead>
            <tr className="text-neutral-600">
              <th scope="col" className="py-1 pr-4 text-left font-normal">hour</th>
              <th scope="col" className="py-1 pr-4 text-left font-normal">stations needed</th>
              <th scope="col" className="py-1 pr-4 text-right font-normal">p90</th>
              <th scope="col" className="py-1 pr-4 text-right font-normal">orders</th>
            </tr>
          </thead>
          <tbody>
            {curve.hours.map((row) => <HourRow key={row.hour} row={row} worst={worst} />)}
          </tbody>
        </table>
      </div>

      {curve.hours.some((h) => !h.achieved) && (
        <p className="mt-3 border-l-2 border-amber-700 pl-3 font-mono text-xs text-amber-600">
          ⚠ At least one hour still misses target at {MAX_STATIONS_TRIED} stations — the shop cannot
          hold {secs(curve.target_seconds)} there by adding baristas alone within the range tried.
        </p>
      )}

      {curve.seeds === 1 && (
        <p className="mt-3 border-l-2 border-neutral-700 pl-3 font-mono text-xs text-neutral-500">
          One day only — a quiet hour's count can move on noise. Raise the day count before staffing
          against it.
        </p>
      )}

      <p className="mt-3 font-mono text-[10px] text-neutral-600">
        each row is the whole day run at that many stations, read at this one hour — not a shift that
        actually varies mid-day (ADR-0020)
      </p>
    </section>
  )
}

function HourRow({ row, worst }: { row: StaffingCurveHour; worst: number }) {
  return (
    <tr className="border-t border-neutral-900">
      <th scope="row" className="py-1.5 pr-4 text-left font-normal tabular-nums text-neutral-300">
        {label(row.hour)}
      </th>
      <td className="py-1.5 pr-4">
        <div className="flex items-center gap-2">
          <div className="h-3 w-32 bg-neutral-900">
            <div
              className={`h-full ${row.achieved ? 'bg-amber-600' : 'bg-rose-700'}`}
              style={{ width: `${Math.max((row.stations / worst) * 100, 4)}%` }}
              role="img"
              aria-label={`${row.stations} stations`}
            />
          </div>
          <span className="tabular-nums text-neutral-300">{row.stations}</span>
          {!row.achieved && (
            <span
              className="text-amber-600"
              title={`Even ${MAX_STATIONS_TRIED} stations missed the target this hour — this is the widest count tried, not an answer.`}
            >
              ⚠
            </span>
          )}
        </div>
      </td>
      <td className="py-1.5 pr-4 text-right tabular-nums text-neutral-300">{secs(row.p90)}</td>
      <td className="py-1.5 pr-4 text-right tabular-nums text-neutral-500">
        {row.orders}
        {!row.p90_meaningful && (
          <span
            className="ml-1 text-amber-600"
            title="Too few orders in this hour for a percentile — this is close to the slowest one, not a p90."
          >
            ⚠
          </span>
        )}
      </td>
    </tr>
  )
}

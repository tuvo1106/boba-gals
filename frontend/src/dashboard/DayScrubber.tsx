/**
 * Picks which part of the day the ribbon shows (DESIGN.md §10.6).
 *
 * The bars are §10.3's arrival profile, so the control also answers "when is it
 * actually busy" — otherwise choosing a window is guesswork and you land in a
 * quiet hour where every policy looks identical. The busiest hours are the only
 * ones where the scheduler is under test at all (§10.3: "flat arrivals will make
 * everything look fine").
 */

import { OPENS_AT } from './clock'

/** Orders per hour, 10:00–21:00 — Simulator::Scenario::DEFAULT_ARRIVAL_PROFILE. */
const ARRIVAL_PROFILE = [ 12, 22, 48, 40, 26, 38, 52, 44, 36, 42, 24 ]

export function DayScrubber({
  from,
  span,
  onChange,
  onCommit,
}: {
  from: number
  span: number
  /** Cheap: moves the window. Fires continuously while the slider is dragged. */
  onChange: (from: number) => void
  /**
   * Expensive: re-runs the simulation for the window that was landed on. Fires
   * once, on release — never mid-drag.
   */
  onCommit: (from: number) => void
}) {
  const dayEnd = ARRIVAL_PROFILE.length * 3600
  const busiest = Math.max(...ARRIVAL_PROFILE)
  // A window wider than the remaining day would show empty space past close.
  const maxFrom = Math.max(dayEnd - span, 0)

  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-end gap-px" role="group" aria-label="jump to hour">
        {ARRIVAL_PROFILE.map((orders, hour) => {
          const start = hour * 3600
          const inWindow = start < from + span && start + 3600 > from

          return (
            <button
              key={hour}
              onClick={() => {
                const next = Math.min(start, maxFrom)
                onChange(next)
                onCommit(next)
              }}
              aria-label={`${OPENS_AT + hour}:00 — ${orders} orders`}
              title={`${OPENS_AT + hour}:00 · ${orders} orders/hour`}
              className={`w-6 origin-bottom transition-colors ${inWindow ? 'bg-amber-500' : 'bg-neutral-700 hover:bg-neutral-500'}`}
              style={{ height: `${(orders / busiest) * 28}px` }}
            />
          )
        })}
      </div>

      {/* Fine control, because the interesting moment is usually a few minutes
          inside an hour rather than on its boundary.

          Dragging only moves the window; the run fires on release. At
          `step={60}` a drag across the day is some 600 increments, and each one
          used to POST a simulation — a whole simulated day of work per pixel,
          against an endpoint §10.5 puts behind the admin session precisely
          because a run is unbounded compute. The hour buttons above commit on
          click, which is right: one click is one deliberate choice.

          This mirrors the demand slider in `DashboardScreen`, which has always
          split `onChange` from `onMouseUp`/`onKeyUp` for the same reason. */}
      <input
        type="range" value={Math.min(from, maxFrom)} min={0} max={maxFrom} step={60}
        aria-label="window start"
        onChange={(e) => onChange(Number(e.target.value))}
        onMouseUp={(e) => onCommit(Number(e.currentTarget.value))}
        onKeyUp={(e) => onCommit(Number(e.currentTarget.value))}
        onTouchEnd={(e) => onCommit(Number(e.currentTarget.value))}
        className="w-[270px] accent-amber-600"
      />
    </div>
  )
}

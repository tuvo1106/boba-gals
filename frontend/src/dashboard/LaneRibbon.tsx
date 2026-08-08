import { useState } from 'react'
import type { TimelineDrink } from '../api/types'
import { shopClock } from './clock'

/**
 * The station-lane ribbon (DESIGN.md §10.6).
 *
 * One horizontal lane per station, drinks as capsules coloured by order. A
 * large order's drinks are visibly *interleaved* with small orders' — which is
 * the point: it makes the fairness claim something you can see rather than
 * infer from a percentile table.
 *
 * §10.6's constraints: an instrument panel, not a marketing page. Hairline
 * rules, no gradients, tabular numerals on every figure.
 */
export function LaneRibbon({
  drinks,
  stations,
  from,
  to,
  pinnedOrder = null,
}: {
  drinks: TimelineDrink[]
  stations: number
  from: number
  to: number
  /** Kept highlighted without the pointer, so a found order stays found. */
  pinnedOrder?: number | null
}) {
  const span = Math.max(to - from, 1)
  const lanes = Array.from({ length: stations }, (_, i) => i)
  const [hovered, setHovered] = useState<TimelineDrink | null>(null)
  // Hover wins while the pointer is down a lane; the pin is what you fall back
  // to, so a search result does not vanish the moment you move the mouse.
  const focusOrder = hovered?.order_id ?? pinnedOrder
  const shown = hovered ?? drinks.find((d) => d.order_id === pinnedOrder) ?? null

  return (
    <figure className="m-0">
      {/* A fixed readout rather than a `title` tooltip: with hundreds of
          capsules you sweep the pointer along a lane, and a tooltip that waits a
          second and then covers its neighbours makes that impossible. Reserved
          height so the ribbon does not jump as the pointer moves. */}
      <Readout drink={shown} from={from} span={span} pinned={hovered === null && shown !== null} />

      <div className="flex flex-col gap-px bg-neutral-800">
        {lanes.map((lane) => (
          <div key={lane} className="flex items-stretch bg-neutral-950" role="row" aria-label={`Station ${lane + 1}`}>
            <span className="flex w-24 shrink-0 items-center pl-3 font-mono text-[11px] tracking-wider text-neutral-500 uppercase">
              Station {lane + 1}
            </span>

            {/* Its own positioning context, so a capsule's left/width stay plain
                percentages of the time window rather than an offset calc. */}
            <div className="relative h-14 grow overflow-hidden">
            {drinks
              .filter((d) => d.station === lane)
              .map((d) => (
                <Capsule
                  key={d.drink_id} drink={d} from={from} span={span}
                  active={focusOrder === d.order_id}
                  dimmed={focusOrder !== null && focusOrder !== d.order_id}
                  onHover={setHovered}
                />
              ))}
            </div>
          </div>
        ))}
      </div>

      <div className="ml-24">
        <Axis from={from} to={to} />
      </div>
    </figure>
  )
}

function Capsule({
  drink, from, span, active, dimmed, onHover,
}: {
  drink: TimelineDrink; from: number; span: number
  active: boolean; dimmed: boolean; onHover: (d: TimelineDrink | null) => void
}) {
  const finish = drink.finished_at ?? from + span
  const left = ((drink.started_at - from) / span) * 100

  // A drink can start inside the window and finish after it. Clamping keeps the
  // capsule inside its lane; the squared-off right edge below says it continues,
  // so a truncated bar does not read as a drink that ended there.
  const runsPast = finish > from + span
  const width = Math.min(((finish - drink.started_at) / span) * 100, 100 - left)

  return (
    <div
      role="button" tabIndex={0}
      aria-label={describe(drink, finish, runsPast)}
      onMouseEnter={() => onHover(drink)}
      onMouseLeave={() => onHover(null)}
      onFocus={() => onHover(drink)}
      onBlur={() => onHover(null)}
      className={`absolute top-2 bottom-2 border transition-opacity ${runsPast ? 'rounded-l-full' : 'rounded-full'} ${active ? 'border-white' : 'border-black/30'} ${dimmed ? 'opacity-25' : 'opacity-100'}`}
      style={{
        left: `${left}%`,
        // Sub-pixel capsules vanish; a drink that ran is always visible. Hover
        // needs a target too — a 1px capsule is unhittable, so the floor is
        // wider than strictly needed to draw it.
        width: `max(${width}%, 4px)`,
        background: orderColour(drink.order_id),
      }}
    >
      {/* Remakes carry a distinct persistent marker (§9.4), so the priority
          floor is visible in the ribbon rather than inferred from metrics. */}
      {drink.remake && (
        <span className="absolute inset-0 rounded-full border-2 border-dashed border-white/70" aria-hidden />
      )}
    </div>
  )
}

/**
 * Hovering one drink names its whole order, because the question the ribbon
 * answers is "where did *this order's* drinks go" — not "what is this one bar".
 * Everything outside the order dims, so the answer is legible without reading.
 */
function Readout({ drink, from, span, pinned }: { drink: TimelineDrink | null; from: number; span: number; pinned: boolean }) {
  if (!drink) {
    return (
      <p className="mb-2 h-6 font-mono text-xs text-neutral-700">
        Hover a drink to trace its order
      </p>
    )
  }

  const finish = drink.finished_at ?? from + span

  return (
    <p className="mb-2 flex h-6 items-center gap-2 font-mono text-sm tabular-nums text-neutral-200">
      <span className="inline-block h-3 w-3 rounded-full" style={{ background: orderColour(drink.order_id) }} aria-hidden />
      {describe(drink, finish, finish > from + span)}
      {pinned && <span className="text-amber-500">· pinned</span>}
    </p>
  )
}

function describe(drink: TimelineDrink, finish: number, runsPast: boolean): string {
  const size = `${drink.order_size} drink${drink.order_size === 1 ? '' : 's'}`

  return [
    `Order ${drink.order_id}`, size,
    `station ${(drink.station ?? 0) + 1}`,
    `${Math.round(finish - drink.started_at)}s${runsPast ? '+' : ''}`,
    drink.remake ? 'remake' : null,
  ].filter(Boolean).join(' · ')
}

/**
 * Colour is identity, not decoration: the eye groups capsules of one hue into
 * "that order", which is how interleaving becomes visible. Derived from the
 * order id so the same order is the same colour across re-renders.
 *
 * Golden-angle hue stepping keeps consecutive orders far apart on the wheel,
 * which matters because consecutive orders are exactly the ones competing.
 */
function orderColour(orderId: number): string {
  const hue = (orderId * 137.508) % 360

  return `hsl(${hue.toFixed(1)} 62% 58%)`
}

function Axis({ from, to }: { from: number; to: number }) {
  const ticks = 5
  const step = (to - from) / (ticks - 1)

  return (
    <figcaption className="mt-1.5 flex justify-between font-mono text-[11px] tabular-nums text-neutral-500">
      {Array.from({ length: ticks }, (_, i) => (
        <span key={i}>{shopClock(from + i * step)}</span>
      ))}
    </figcaption>
  )
}

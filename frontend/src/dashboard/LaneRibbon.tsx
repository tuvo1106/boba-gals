import type { TimelineDrink } from '../api/types'

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
}: {
  drinks: TimelineDrink[]
  stations: number
  from: number
  to: number
}) {
  const span = Math.max(to - from, 1)
  const lanes = Array.from({ length: stations }, (_, i) => i)

  return (
    <figure className="m-0">
      <div className="flex flex-col gap-px bg-neutral-800">
        {lanes.map((lane) => (
          <div key={lane} className="flex items-stretch bg-neutral-950" role="row" aria-label={`Station ${lane + 1}`}>
            <span className="flex w-20 shrink-0 items-center pl-2 font-mono text-[10px] tracking-wider text-neutral-600 uppercase">
              Station {lane + 1}
            </span>

            {/* Its own positioning context, so a capsule's left/width stay plain
                percentages of the time window rather than an offset calc. */}
            <div className="relative h-9 grow">
            {drinks
              .filter((d) => d.station === lane)
              .map((d) => (
                <Capsule key={d.drink_id} drink={d} from={from} span={span} />
              ))}
            </div>
          </div>
        ))}
      </div>

      <div className="ml-20">
        <Axis from={from} to={to} />
      </div>
    </figure>
  )
}

function Capsule({ drink, from, span }: { drink: TimelineDrink; from: number; span: number }) {
  const finish = drink.finished_at ?? from + span
  const left = ((drink.started_at - from) / span) * 100
  const width = ((finish - drink.started_at) / span) * 100

  return (
    <div
      className="absolute top-1.5 bottom-1.5 rounded-full border border-black/30"
      style={{
        left: `${left}%`,
        // Sub-pixel capsules vanish; a drink that ran is always visible.
        width: `max(${width}%, 2px)`,
        background: orderColour(drink.order_id),
      }}
      title={`Order ${drink.order_id} · ${drink.order_size} drink${drink.order_size === 1 ? '' : 's'} · ${Math.round(finish - drink.started_at)}s${drink.remake ? ' · remake' : ''}`}
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
    <figcaption className="mt-1 flex justify-between font-mono text-[10px] tabular-nums text-neutral-600">
      {Array.from({ length: ticks }, (_, i) => (
        <span key={i}>{formatClock(from + i * step)}</span>
      ))}
    </figcaption>
  )
}

/** Simulated seconds are relative to a 10:00 open (§10.3's profile). */
function formatClock(seconds: number): string {
  const total = Math.round(seconds)
  const h = 10 + Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)

  return `${h}:${String(m).padStart(2, '0')}`
}

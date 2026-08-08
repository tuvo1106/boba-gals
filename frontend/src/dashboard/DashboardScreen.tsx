import { useEffect, useState } from 'react'
import { LaneRibbon } from './LaneRibbon'
import { DayScrubber } from './DayScrubber'
import { shopClock } from './clock'
import type { Policy, SimulationRun } from '../api/types'

/** §6.3's arms, in the order the ablation reads: least fair to most. */
const POLICIES: { id: Policy; title: string }[] = [
  { id: 'fifo', title: 'Strict arrival order. Best for the catering order, worst for everyone behind it.' },
  { id: 'rr', title: 'One drink per order per turn, ignoring how long each takes. DRR without the deficit.' },
  { id: 'drr', title: 'Deficit round robin: equal barista *time* per order rather than equal turns.' },
  { id: 'sjf', title: 'Always the shortest queued drink. The mean-wait floor, and never a shippable policy.' },
]

/**
 * The simulation dashboard (DESIGN.md §10.6), starting with its signature
 * element. "Build this first; it will teach you more about the scheduler than
 * any number."
 *
 * An instrument panel, not a marketing page: tabular-numeral monospace for all
 * figures, hairline rules, one accent colour, no gradients.
 */
export function DashboardScreen() {
  const [run, setRun] = useState<SimulationRun | null>(null)
  // §10.6: "the previous run ghosted behind the current one for comparison". A
  // number with nothing to compare against is not a verdict.
  const [previous, setPrevious] = useState<{ run: SimulationRun; policy: string } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [seed, setSeed] = useState(7)
  const [policy, setPolicy] = useState<Policy>('drr')
  // Zoom. A full day is ~700 drinks and every capsule would be sub-pixel; 20
  // minutes shows about 40. Wider answers "does this hold all day", narrower
  // answers "what exactly happened here".
  const [span, setSpan] = useState(1200)
  // Where in the day to look. Defaults to the lunch peak — §10.3 puts 48
  // orders/hour in the third hour, and a quiet window shows one station doing
  // everything, which teaches nothing.
  const [from, setFrom] = useState(7200)
  // Load, per §10.6's config rail. Only these two knobs for now: they answer
  // "what happens as the shop gets busier", which is a trend across runs and so
  // does not need the two runs to be the same day. The ablation toggles
  // (quantum, aging, cohesion) do, and wait on common random numbers.
  const [stations, setStations] = useState(3)
  const [demand, setDemand] = useState(1)
  const [find, setFind] = useState('')
  const [pinned, setPinned] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)

  async function go(
    nextSeed = seed, nextPolicy = policy, nextSpan = span, nextFrom = from,
    nextStations = stations, nextDemand = demand,
  ) {
    setBusy(true)
    setError(null)
    try {
      const response = await fetch('/api/v1/admin/simulations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({
          seed: nextSeed,
          stations: nextStations,
          demand_multiplier: nextDemand,
          scheduler_config: { policy: nextPolicy },
          window_from: nextFrom,
          window_seconds: nextSpan,
        }),
      })
      if (!response.ok) throw new Error(response.status === 401 ? 'Sign in as admin first' : `Run failed (${response.status})`)
      const next = (await response.json()) as SimulationRun
      setRun((current) => {
        if (current) setPrevious({ run: current, policy })
        return next
      })
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Run failed')
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => { go() }, []) // eslint-disable-line react-hooks/exhaustive-deps

  /**
   * Scrub to where an order was actually made. Order ids run in arrival order,
   * but an order-ahead order (§10.3) is dispatched hours later — so "show me
   * order 1" cannot be answered by arithmetic on the id, only by the span index.
   */
  function locate(id: number) {
    const span_ = run?.order_spans.find(([ orderId ]) => orderId === id)
    if (!span_) {
      setError(`Order ${id} was never made in this run`)
      setPinned(null)
      return
    }

    const [ , start, finish ] = span_
    // Centre the order when it fits, otherwise open at its first drink.
    const width = finish - start
    const nextFrom = Math.max(width < span ? start - (span - width) / 2 : start - 30, 0)

    setError(null)
    setPinned(id)
    setFrom(nextFrom)
    go(seed, policy, span, nextFrom)
  }

  return (
    <main className="min-h-screen bg-neutral-950 p-6 text-neutral-200">
      <header className="mb-5 flex flex-wrap items-baseline gap-x-6 gap-y-2 border-b border-neutral-800 pb-3">
        <h1 className="font-mono text-sm tracking-widest text-neutral-500 uppercase">Station lanes</h1>

        {/* "Every run must display its seed" (§10.6). */}
        <label className="font-mono text-xs text-neutral-500">
          seed{' '}
          <input
            type="number" value={seed} aria-label="seed"
            onChange={(e) => setSeed(Number(e.target.value))}
            className="w-16 border-b border-neutral-700 bg-transparent tabular-nums text-neutral-200 focus:border-amber-500 focus:outline-none"
          />
        </label>

        {/* §6.3's control arm, selectable — seeing FIFO next to DRR is the
            comparison the whole design rests on. */}
        {/* §6.3's arms. RR is DRR without the deficit and SJF is the mean-wait
            floor; both are simulator-only — `UpdateSchedulerConfig` refuses
            them, because SJF starves large orders whenever drink cost tracks
            order size. */}
        <div className="flex gap-1 font-mono text-xs" role="group" aria-label="policy">
          {POLICIES.map(({ id: p, title }) => (
            <button
              key={p} onClick={() => { setPolicy(p); go(seed, p) }} title={title}
              className={`px-2 py-0.5 uppercase ${policy === p ? 'bg-amber-600 text-neutral-950' : 'text-neutral-500 hover:text-neutral-300'}`}
            >
              {p}
            </button>
          ))}
        </div>

        <label className="font-mono text-xs text-neutral-500">
          showing{' '}
          <select
            value={span} aria-label="window"
            onChange={(e) => { const v = Number(e.target.value); setSpan(v); go(seed, policy, v) }}
            className="border-b border-neutral-700 bg-neutral-950 text-neutral-200 focus:border-amber-500 focus:outline-none"
          >
            <option value={300}>5 min</option>
            <option value={1200}>20 min</option>
            <option value={3600}>1 hour</option>
            <option value={10800}>3 hours</option>
          </select>
        </label>

        <div className="flex items-end gap-2">
          <DayScrubber
            from={from} span={span}
            onChange={(v) => { setFrom(v); go(seed, policy, span, v) }}
          />
          <span className="font-mono text-xs tabular-nums text-neutral-400">
            {shopClock(from)}–{shopClock(from + span)}
          </span>
        </div>

        {/* Ids are the only stable handle on an order — the board shows first
            name and code (§3), and the ribbon shows colour, so a number is how
            you say "that one" out loud. */}
        <form
          className="font-mono text-xs text-neutral-500"
          onSubmit={(e) => { e.preventDefault(); const id = Number(find); if (id > 0) locate(id) }}
        >
          <label>
            find order{' '}
            <input
              type="number" min={1} value={find} aria-label="find order"
              onChange={(e) => setFind(e.target.value)}
              className="w-16 border-b border-neutral-700 bg-transparent tabular-nums text-neutral-200 focus:border-amber-500 focus:outline-none"
            />
          </label>
          {/* Explicit, not just Enter: a bare number field does not advertise
              that it is submittable. */}
          <button type="submit" className="ml-1 text-neutral-500 hover:text-amber-500">go</button>
          {pinned !== null && (
            <button
              type="button" onClick={() => { setPinned(null); setFind('') }}
              className="ml-2 text-amber-500 hover:text-amber-400"
            >
              clear
            </button>
          )}
        </form>

        <button
          onClick={() => go()} disabled={busy}
          className="ml-auto border border-neutral-700 px-3 py-1 font-mono text-xs uppercase hover:border-amber-500 disabled:opacity-40"
        >
          {busy ? 'Running…' : 'Run'}
        </button>
      </header>

      {/* Separated from the header deliberately: these change the *day*, while
          seed aside the header's controls only change what you look at. */}
      <div className="mb-4 flex flex-wrap items-center gap-x-8 gap-y-2 font-mono text-xs">
        <div className="flex items-center gap-2">
          <span className="text-neutral-500">stations</span>
          {[ 1, 2, 3, 4, 5, 6 ].map((n) => (
            <button
              key={n} onClick={() => { setStations(n); go(seed, policy, span, from, n) }}
              className={`w-6 tabular-nums ${stations === n ? 'bg-amber-600 text-neutral-950' : 'text-neutral-500 hover:text-neutral-300'}`}
            >
              {n}
            </button>
          ))}
        </div>

        <label className="flex items-center gap-2">
          <span className="text-neutral-500">demand</span>
          <input
            type="range" value={demand} min={0.5} max={3} step={0.1} aria-label="demand"
            onChange={(e) => setDemand(Number(e.target.value))}
            onMouseUp={() => go(seed, policy, span, from, stations, demand)}
            onKeyUp={() => go(seed, policy, span, from, stations, demand)}
            className="w-40 accent-amber-600"
          />
          <span className="w-8 tabular-nums text-neutral-300">{demand.toFixed(1)}×</span>
        </label>

        {/* The point of both knobs: §10.4's threshold is a cliff, not a slope,
            and you only believe that by walking up to it. */}
        <p className="text-[11px] text-neutral-600">
          Push these until utilisation passes 85% — waits and walkaways go nonlinear, not linear.
        </p>
      </div>

      {error && <p role="alert" className="font-mono text-sm text-amber-500">{error}</p>}

      {run && (
        <>
          <Verdict run={run} policy={policy} previous={previous} />

          <LaneRibbon
            drinks={run.timeline} stations={run.stations}
            from={run.window.from} to={run.window.to}
            pinnedOrder={pinned}
          />

          <Legend />

          {/* Every figure carries what it measures and which direction is good.
              An operator reading "0.912" has no way to know that is the number
              that decides whether to add a fourth station. */}
          <dl className="mt-6 grid grid-cols-1 gap-x-8 gap-y-3 font-mono text-xs sm:grid-cols-2 lg:grid-cols-4">
            <Figure
              label="small-order p90" value={`${run.metrics.by_size_class['1-2'].p90}s`} accent
              hint="9 of 10 orders of 1–2 drinks were ready within this. The headline number — if it stays flat as large orders arrive, fair queuing is working (§10.4)."
            />
            <Figure
              label="7+ p90" value={`${run.metrics.by_size_class['7+'].p90}s`}
              hint="The same for catering orders. Expected to be higher — they are more drinks. The claim is that it rises while the line above does not."
            />
            <Figure
              label="utilisation" value={pct(run.metrics.station_utilisation)}
              state={utilisationState(run.metrics.station_utilisation)}
              hint="Share of barista time spent making drinks. Past ~85% queues grow nonlinearly, so this is the number that decides staffing (§10.4)."
            />
            <Figure
              label="orders served" value={String(run.metrics.orders)}
              hint={`${run.metrics.drinks} drinks across an 11-hour day, 10:00–21:00.`}
            />
            <Figure
              label="remakes" value={String(run.metrics.remakes)}
              hint="Drinks made wrong and remade. A remake is a new drink on the same order and gets a priority floor, so it does not go to the back (§5.2, §6.4)."
            />
            <Figure
              label="walked away" value={String(run.metrics.reneged)}
              state={run.metrics.reneged > 0 ? 'warn' : 'good'}
              hint="Web customers who saw the quoted wait and left without ordering. This prices slowness in lost sales rather than seconds (§10.3)."
            />
            <Figure
              label="sat too long" value={pct(run.metrics.quality_breach_rate_multi)}
              state={run.metrics.quality_breach_rate_multi > 0.25 ? 'warn' : 'good'}
              hint={`Drinks in multi-drink orders that waited over 5 minutes on the counter — ice melts, and this is what cohesion exists to reduce (§9.6). Across all orders it is ${pct(run.metrics.quality_breach_rate)}, but a lone drink's wait is just the customer walking over, which no schedule can improve.`}
            />
            <Figure
              label="seed" value={String(run.seed)}
              hint="Type this seed above to replay this exact day. Every run is a pure function of it (§10.2)."
            />
          </dl>
        </>
      )}
    </main>
  )
}

/**
 * The headline, in words (§10.4): "small-order p90 wait vs. concurrent
 * large-order rate. If fair queuing is working, that line is flat."
 *
 * A ribbon without this is a picture with no claim attached — you can see that
 * the colours differ between policies without knowing which way is better.
 */
function Verdict({
  run,
  policy,
  previous,
}: {
  run: SimulationRun
  policy: string
  previous: { run: SimulationRun; policy: string } | null
}) {
  const small = run.metrics.by_size_class['1-2'].p90
  const large = run.metrics.by_size_class['7+'].p90
  const against =
    previous && previous.policy !== policy && previous.run.seed === run.seed ? previous : null
  const delta = against ? small - against.run.metrics.by_size_class['1-2'].p90 : null

  return (
    <section className="mb-4 border-l-2 border-amber-600 pl-3">
      <p className="font-mono text-sm text-neutral-300">
        A customer ordering <strong className="text-neutral-100">1–2 drinks</strong> waited{' '}
        <strong className="tabular-nums text-amber-500">{small}s</strong> at the 90th percentile.
        Someone ordering <strong className="text-neutral-100">7+</strong> waited{' '}
        <span className="tabular-nums">{large}s</span>.
      </p>

      {delta !== null ? (
        <p className="mt-1 font-mono text-xs text-neutral-400">
          {delta < 0 ? (
            <>
              <span className="text-emerald-400">{Math.abs(delta).toFixed(1)}s faster</span> than{' '}
              {against?.policy.toUpperCase()} on the same day — small orders are not stuck behind large ones.
            </>
          ) : (
            <>
              <span className="text-amber-500">{delta.toFixed(1)}s slower</span> than{' '}
              {against?.policy.toUpperCase()} on the same day.
            </>
          )}
        </p>
      ) : (
        <p className="mt-1 font-mono text-xs text-neutral-600">
          Switch policy to compare the same day under another arm — identical
          arrivals, identical drinks (ADR-0011).
        </p>
      )}
    </section>
  )
}

/** A ribbon is unreadable without a key to what its shapes mean. */
function Legend() {
  return (
    <ul className="mt-4 ml-24 flex flex-wrap gap-x-6 gap-y-1 font-mono text-[11px] text-neutral-500">
      <li className="flex items-center gap-1.5">
        <span className="h-3 w-6 rounded-full" style={{ background: 'hsl(137.5 62% 58%)' }} />
        one drink — width is how long it took
      </li>
      <li className="flex items-center gap-1.5">
        <span className="flex gap-0.5">
          <span className="h-3 w-3 rounded-full" style={{ background: 'hsl(275 62% 58%)' }} />
          <span className="h-3 w-3 rounded-full" style={{ background: 'hsl(275 62% 58%)' }} />
        </span>
        same colour = same order
      </li>
      <li className="flex items-center gap-1.5">
        <span className="h-3 w-6 rounded-full border-2 border-dashed border-white/70" style={{ background: 'hsl(50 62% 58%)' }} />
        remake
      </li>
      <li>rows are stations · left to right is time</li>
    </ul>
  )
}

/** Semantic state is deliberately not the amber accent — "needs attention" and
 *  "this is the headline" are different claims and must not share a colour. */
const STATE_COLOUR = {
  good: 'text-emerald-400',
  warn: 'text-orange-400',
  bad: 'text-rose-400',
} as const

function Figure({
  label, value, hint, accent = false, state,
}: {
  label: string; value: string; hint: string
  accent?: boolean; state?: keyof typeof STATE_COLOUR
}) {
  const colour = state ? STATE_COLOUR[state] : accent ? 'text-amber-500' : 'text-neutral-200'

  return (
    <div className="border-t border-neutral-800 pt-1">
      <dt className="text-[10px] tracking-wider text-neutral-600 uppercase">{label}</dt>
      <dd className={`text-base tabular-nums ${colour}`}>{value}</dd>
      <p className="mt-0.5 text-[10px] leading-snug text-neutral-500">{hint}</p>
    </div>
  )
}

function pct(fraction: number): string {
  return `${(fraction * 100).toFixed(1)}%`
}

/**
 * §10.4's threshold: "past ~85% queues grow nonlinearly". Below 70% the shop is
 * overstaffed for this demand, which is a finding too — it is where the
 * dashboard says you could run a station lighter.
 */
function utilisationState(u: number): keyof typeof STATE_COLOUR {
  if (u >= 0.85) return 'bad'
  if (u >= 0.7) return 'warn'

  return 'good'
}

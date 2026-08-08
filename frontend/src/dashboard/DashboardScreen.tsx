import { useEffect, useState } from 'react'
import { LaneRibbon } from './LaneRibbon'
import type { SimulationRun } from '../api/types'

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
  const [policy, setPolicy] = useState<'drr' | 'fifo'>('drr')
  // Zoom. A full day is ~700 drinks and every capsule would be sub-pixel; 20
  // minutes shows about 40. Wider answers "does this hold all day", narrower
  // answers "what exactly happened here".
  const [span, setSpan] = useState(1200)
  const [busy, setBusy] = useState(false)

  async function go(nextSeed = seed, nextPolicy = policy, nextSpan = span) {
    setBusy(true)
    setError(null)
    try {
      const response = await fetch('/api/v1/admin/simulations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({
          seed: nextSeed,
          scheduler_config: { policy: nextPolicy },
          // The lunch peak — §10.3 puts 48 orders/hour in the third hour, and a
          // quiet window shows one station doing everything.
          window_from: 7200,
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
        <div className="flex gap-1 font-mono text-xs">
          {(['drr', 'fifo'] as const).map((p) => (
            <button
              key={p} onClick={() => { setPolicy(p); go(seed, p) }}
              className={`px-2 py-0.5 uppercase ${policy === p ? 'bg-amber-600 text-neutral-950' : 'text-neutral-500 hover:text-neutral-300'}`}
            >
              {p}
            </button>
          ))}
        </div>

        <label className="font-mono text-xs text-neutral-500">
          window{' '}
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

        <button
          onClick={() => go()} disabled={busy}
          className="ml-auto border border-neutral-700 px-3 py-1 font-mono text-xs uppercase hover:border-amber-500 disabled:opacity-40"
        >
          {busy ? 'Running…' : 'Run'}
        </button>
      </header>

      {error && <p role="alert" className="font-mono text-sm text-amber-500">{error}</p>}

      {run && (
        <>
          <Verdict run={run} policy={policy} previous={previous} />

          <LaneRibbon
            drinks={run.timeline} stations={run.stations}
            from={run.window.from} to={run.window.to}
          />

          <Legend />

          <dl className="mt-6 grid grid-cols-2 gap-x-8 gap-y-2 font-mono text-xs sm:grid-cols-4">
            <Figure label="small-order p90" value={`${run.metrics.by_size_class['1-2'].p90}s`} accent />
            <Figure label="7+ p90" value={`${run.metrics.by_size_class['7+'].p90}s`} />
            <Figure label="utilisation" value={run.metrics.station_utilisation.toFixed(3)} />
            <Figure label="orders" value={String(run.metrics.orders)} />
            <Figure label="remakes" value={String(run.metrics.remakes)} />
            <Figure label="lost to waits" value={String(run.metrics.reneged)} />
            <Figure label="quality breach" value={run.metrics.quality_breach_rate.toFixed(3)} />
            <Figure label="seed" value={String(run.seed)} />
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
          Switch policy to compare the same day under {policy === 'drr' ? 'FIFO' : 'DRR'}.
        </p>
      )}
    </section>
  )
}

/** A ribbon is unreadable without a key to what its shapes mean. */
function Legend() {
  return (
    <ul className="mt-3 flex flex-wrap gap-x-6 gap-y-1 font-mono text-[10px] text-neutral-500">
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

function Figure({ label, value, accent = false }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="border-t border-neutral-800 pt-1">
      <dt className="text-[10px] uppercase tracking-wider text-neutral-600">{label}</dt>
      <dd className={`tabular-nums ${accent ? 'text-amber-500' : 'text-neutral-200'}`}>{value}</dd>
    </div>
  )
}

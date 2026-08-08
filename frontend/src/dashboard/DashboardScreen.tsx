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
  const [error, setError] = useState<string | null>(null)
  const [seed, setSeed] = useState(7)
  const [policy, setPolicy] = useState<'drr' | 'fifo'>('drr')
  const [busy, setBusy] = useState(false)

  async function go(nextSeed = seed, nextPolicy = policy) {
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
          window_seconds: 1200,
        }),
      })
      if (!response.ok) throw new Error(response.status === 401 ? 'Sign in as admin first' : `Run failed (${response.status})`)
      setRun((await response.json()) as SimulationRun)
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
          <LaneRibbon
            drinks={run.timeline} stations={run.stations}
            from={run.window.from} to={run.window.to}
          />

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

function Figure({ label, value, accent = false }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="border-t border-neutral-800 pt-1">
      <dt className="text-[10px] uppercase tracking-wider text-neutral-600">{label}</dt>
      <dd className={`tabular-nums ${accent ? 'text-amber-500' : 'text-neutral-200'}`}>{value}</dd>
    </div>
  )
}

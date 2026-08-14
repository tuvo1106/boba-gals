import { useEffect, useState } from 'react'
import { LaneRibbon } from './LaneRibbon'
import { DayScrubber } from './DayScrubber'
import { AdminSignIn } from './AdminSignIn'
import { AblationBars } from './AblationBars'
import { QuantumSweepChart } from './QuantumSweepChart'
import { StaffingCurveTable } from './StaffingCurveTable'
import { BreakingPointChart } from './BreakingPointChart'
import { MetricGrid } from './MetricGrid'
import { useAdminSession } from './useAdminSession'
import { shopClock } from './clock'
import type {
  Ablation, AdminUser, BreakingPoint, Policy, QuantumSweep, SchedulerConfig, StaffingCurve,
  SimulationRun,
} from '../api/types'

/** §6.3's arms, in the order the ablation reads: least fair to most. */
const POLICIES: { id: Policy; title: string }[] = [
  { id: 'fifo', title: 'Strict arrival order. Best for the catering order, worst for everyone behind it.' },
  { id: 'rr', title: 'One drink per order per turn, ignoring how long each takes. DRR without the deficit.' },
  { id: 'drr', title: 'Deficit round robin: equal barista *time* per order rather than equal turns.' },
  { id: 'sjf', title: 'Always the shortest queued drink. The mean-wait floor, and never a shippable policy.' },
]

/**
 * The dashboard's door (§13.4).
 *
 * A hard gate, the way the KDS gates on its station token: signed out renders
 * the form and *nothing else*. Not a disabled panel — the config rail holds the
 * same scheduler knobs that apply-to-store writes to the live store (§10.6), and
 * every visible-but-dead control teaches an operator that the dashboard is
 * broken rather than that they are signed out.
 *
 * `checking` renders nothing at all rather than the form, or every reload
 * flashes a sign-in screen at someone who is already signed in.
 */
export function DashboardScreen() {
  const { session, signIn, signOut, expired } = useAdminSession()

  if (session.status === 'checking') {
    return <main className="min-h-screen bg-neutral-950" aria-busy="true" />
  }

  if (session.status === 'signed_out') return <AdminSignIn onSignIn={signIn} />

  return <Dashboard admin={session.admin} onSignOut={signOut} onExpired={expired} />
}

/**
 * The simulation dashboard (DESIGN.md §10.6), starting with its signature
 * element. "Build this first; it will teach you more about the scheduler than
 * any number."
 *
 * An instrument panel, not a marketing page: tabular-numeral monospace for all
 * figures, hairline rules, one accent colour, no gradients.
 */
function Dashboard({
  admin,
  onSignOut,
  onExpired,
}: {
  admin: AdminUser
  onSignOut: () => void
  onExpired: () => void
}) {
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
  // Off by default. Every figure carrying three lines of explanation turned the
  // panel into a wall of prose you read once and then scroll past forever.
  const [explain, setExplain] = useState(false)
  // §10.6 re-runs on every config change because a run is fast. The ablation is
  // four runs per day and is asked for explicitly instead — and because it is a
  // comparison, not a view of the current settings, it should not silently
  // change underneath the reading someone is taking from it.
  const [ablation, setAblation] = useState<Ablation | null>(null)
  const [ablationDays, setAblationDays] = useState(1)
  const [comparing, setComparing] = useState(false)
  // §10.5 #2, same reasoning as the ablation above: ten runs is asked for
  // explicitly rather than re-run on every config change.
  const [sweep, setSweep] = useState<QuantumSweep | null>(null)
  const [sweepDays, setSweepDays] = useState(1)
  const [sweeping, setSweeping] = useState(false)
  // §10.5 #3, same reasoning again: eight runs per day, asked for explicitly.
  const [staffing, setStaffing] = useState<StaffingCurve | null>(null)
  const [staffingDays, setStaffingDays] = useState(1)
  const [target, setTarget] = useState(600)
  const [staffingBusy, setStaffingBusy] = useState(false)
  // §10.5 #4, same reasoning again: up to fourteen runs per day, asked for
  // explicitly. Sweeps demand itself, so — unlike the three experiments
  // above — it does not take the demand slider's value as an input.
  const [breakingPoint, setBreakingPoint] = useState<BreakingPoint | null>(null)
  const [breakingDays, setBreakingDays] = useState(1)
  const [breakingTarget, setBreakingTarget] = useState(900)
  const [breaking, setBreaking] = useState(false)
  // §10.6's "Apply to store": what's actually live, versus what the config
  // rail is set to. `null` until the first fetch resolves — the button stays
  // disabled rather than guessing, since applying against a stale or absent
  // read is exactly the "dashboard state silently becomes production state"
  // failure §10.6 warns against.
  const [liveConfig, setLiveConfig] = useState<SchedulerConfig | null>(null)
  const [confirmingApply, setConfirmingApply] = useState(false)
  const [applying, setApplying] = useState(false)
  const [applyError, setApplyError] = useState<string | null>(null)

  async function compare(days = ablationDays) {
    setComparing(true)
    setError(null)
    try {
      const response = await fetch('/api/v1/admin/ablations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({
          seed, stations, demand_multiplier: demand, seeds: days,
        }),
      })
      if (response.status === 401) {
        onExpired()
        return
      }
      if (!response.ok) throw new Error(`Comparison failed (${response.status})`)
      setAblation((await response.json()) as Ablation)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Comparison failed')
    } finally {
      setComparing(false)
    }
  }

  async function sweepQuantum(days = sweepDays) {
    setSweeping(true)
    setError(null)
    try {
      const response = await fetch('/api/v1/admin/quantum_sweeps', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({
          seed, stations, demand_multiplier: demand, seeds: days,
        }),
      })
      if (response.status === 401) {
        onExpired()
        return
      }
      if (!response.ok) throw new Error(`Sweep failed (${response.status})`)
      setSweep((await response.json()) as QuantumSweep)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Sweep failed')
    } finally {
      setSweeping(false)
    }
  }

  async function staff(days = staffingDays, targetSeconds = target) {
    setStaffingBusy(true)
    setError(null)
    try {
      const response = await fetch('/api/v1/admin/staffing_curves', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({
          seed, demand_multiplier: demand, seeds: days, target_seconds: targetSeconds,
        }),
      })
      if (response.status === 401) {
        onExpired()
        return
      }
      if (!response.ok) throw new Error(`Staffing curve failed (${response.status})`)
      setStaffing((await response.json()) as StaffingCurve)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Staffing curve failed')
    } finally {
      setStaffingBusy(false)
    }
  }

  async function findBreakingPoint(days = breakingDays, targetSeconds = breakingTarget) {
    setBreaking(true)
    setError(null)
    try {
      const response = await fetch('/api/v1/admin/breaking_points', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({
          seed, stations, seeds: days, target_seconds: targetSeconds,
        }),
      })
      if (response.status === 401) {
        onExpired()
        return
      }
      if (!response.ok) throw new Error(`Breaking point failed (${response.status})`)
      setBreakingPoint((await response.json()) as BreakingPoint)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Breaking point failed')
    } finally {
      setBreaking(false)
    }
  }

  // A background status read, not a user-initiated action — failing here
  // shows up as "Apply to store" staying disabled (its title says why),
  // rather than the same page-wide alert a failed run or sweep would raise.
  // That banner is for things the operator asked for; this is a check they
  // didn't.
  async function fetchLiveConfig() {
    try {
      const response = await fetch('/api/v1/admin/scheduler_config', { credentials: 'same-origin' })

      if (response.status === 401) {
        onExpired()
        return
      }
      if (!response.ok) return
      const body = (await response.json()) as { scheduler_config: SchedulerConfig }

      setLiveConfig(body.scheduler_config)
    } catch {
      // liveConfig stays null; the button's own title covers this case.
    }
  }

  // §10.6: "writes the current config to stores.scheduler_config, with a
  // confirmation showing the diff. Never let dashboard state silently become
  // production state." `confirmingApply` is that confirmation — this only
  // runs once the operator has already seen the diff and clicked through it.
  async function applyToStore() {
    setApplying(true)
    setApplyError(null)
    try {
      const response = await fetch('/api/v1/admin/scheduler_config', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({ scheduler_config: { policy } }),
      })
      if (response.status === 401) {
        onExpired()
        return
      }
      const body = (await response.json()) as { scheduler_config?: SchedulerConfig; errors?: string[] }
      if (!response.ok) throw new Error(body.errors?.join(', ') ?? `Apply failed (${response.status})`)

      setLiveConfig(body.scheduler_config ?? null)
      setConfirmingApply(false)
    } catch (e) {
      setApplyError(e instanceof Error ? e.message : 'Apply failed')
    } finally {
      setApplying(false)
    }
  }

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
      // A 401 here means the session went away underneath the run — expired, or
      // signed out in another tab. Back to the form: leaving the panel up with
      // "sign in first" written in the error slot is a dead screen that names
      // its problem without offering the fix.
      if (response.status === 401) {
        onExpired()
        return
      }
      if (!response.ok) throw new Error(`Run failed (${response.status})`)
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

  useEffect(() => { go(); fetchLiveConfig() }, []) // eslint-disable-line react-hooks/exhaustive-deps

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
      <header className="mb-5 border-b border-neutral-800 pb-3">
        {/* Who, and a way out — top-right of the page, above the run controls,
            which is where a back-office user looks for it (issue #63). A
            dashboard that can change live scheduler behaviour (§10.6) should
            not be left signed in on a back-office machine because there was
            no button to leave it.

            Its own row rather than folded into the controls row below: that
            row reflows as the window narrows, which used to carry sign-out
            down onto its own line anyway, floating at the right with nothing
            beside it — this makes that the deliberate layout instead of a
            wrap accident. */}
        <div className="flex items-baseline justify-between gap-3">
          <h1 className="font-mono text-sm tracking-widest text-neutral-500 uppercase">Station lanes</h1>

          {/* One group: as two siblings the identity and its control land on
              different lines the moment the window is narrow, and a bare
              "sign out" under the title reads as a heading. */}
          <div className="flex items-baseline gap-3">
            <span className="font-mono text-xs text-neutral-600" title={admin.email}>
              {admin.email}
            </span>
            <button
              onClick={onSignOut}
              className="font-mono text-xs text-neutral-500 underline decoration-neutral-700 underline-offset-4 hover:text-neutral-300"
            >
              sign out
            </button>
          </div>
        </div>

        <div className="mt-3 flex flex-wrap items-baseline gap-x-6 gap-y-2">
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
                key={p}
                onClick={() => { setPolicy(p); setConfirmingApply(false); setApplyError(null); go(seed, p) }}
                title={title}
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
            onClick={() => setExplain((on) => !on)}
            aria-pressed={explain}
            title="Explain what each figure measures"
            className={`border px-2 py-1 font-mono text-xs ${explain ? 'border-amber-500 text-amber-500' : 'border-neutral-700 text-neutral-500 hover:text-neutral-300'}`}
          >
            ?
          </button>

          <button
            onClick={() => go()} disabled={busy}
            className="border border-neutral-700 px-3 py-1 font-mono text-xs uppercase hover:border-amber-500 disabled:opacity-40"
          >
            {busy ? 'Running…' : 'Run'}
          </button>
        </div>
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

      </div>

      {/* Its own box, deliberately: the masthead's policy buttons and this
          row answer different questions — "what am I simulating" against
          "what is the shop actually running" — and had no line between them
          when this lived inline in the header. A reader could not tell
          which policy button was about to write to production. */}
      <div className="mb-4 flex flex-wrap items-center gap-3 border border-neutral-800 px-3 py-2">
        <span className="font-mono text-xs tracking-widest text-neutral-600 uppercase">Live store</span>
        <ApplyToStore
          policy={policy} liveConfig={liveConfig} confirming={confirmingApply} applying={applying}
          error={applyError}
          onRequestApply={() => setConfirmingApply(true)}
          onCancel={() => { setConfirmingApply(false); setApplyError(null) }}
          onConfirm={applyToStore}
        />
      </div>

      {error && <p role="alert" className="font-mono text-sm text-amber-500">{error}</p>}

      {run && (
        <>
          <Verdict
            run={run} policy={policy} previous={previous}
            quiet={run.metrics.station_utilisation < 0.6}
          />

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
              explain={explain} label="small-order p90" value={`${run.metrics.by_size_class['1-2'].p90}s`}
              accent={run.metrics.by_size_class['1-2'].p90_meaningful}
              state={run.metrics.by_size_class['1-2'].p90_meaningful ? undefined : 'warn'}
              hint={
                run.metrics.by_size_class['1-2'].p90_meaningful
                  ? `9 of 10 orders of 1–2 drinks were ready within this, over ${run.metrics.by_size_class['1-2'].orders} of them. The headline number — if it stays flat as large orders arrive, fair queuing is working (§10.4).`
                  : `Only ${run.metrics.by_size_class['1-2'].orders} small orders in this run, so this is close to their slowest rather than a percentile.`
              }
            />
            <Figure
              explain={explain} label="7+ p90" value={`${run.metrics.by_size_class['7+'].p90}s`}
              state={run.metrics.by_size_class['7+'].p90_meaningful ? undefined : 'warn'}
              hint={
                run.metrics.by_size_class['7+'].p90_meaningful
                  ? `The same for catering orders, over ${run.metrics.by_size_class['7+'].orders} of them. Expected to be higher — they are more drinks. The claim is that it rises while the line above does not.`
                  : `Only ${run.metrics.by_size_class['7+'].orders} catering orders in this run, so this is their slowest one rather than a percentile. Raise demand to get enough of them to compare policies on.`
              }
            />
            <Figure
              explain={explain} label="utilisation" value={pct(run.metrics.station_utilisation)}
              state={utilisationState(run.metrics.station_utilisation)}
              hint="Share of barista time spent making drinks. Past ~85% queues grow nonlinearly, so this is the number that decides staffing (§10.4)."
            />
            <Figure
              explain={explain} label="orders served" value={String(run.metrics.orders)}
              hint={`${run.metrics.drinks} drinks across an 11-hour day, 10:00–21:00.`}
            />
            <Figure
              explain={explain} label="remakes" value={String(run.metrics.remakes)}
              hint="Drinks made wrong and remade. A remake is a new drink on the same order and gets a priority floor, so it does not go to the back (§5.2, §6.4)."
            />
            <Figure
              explain={explain} label="walked away" value={String(run.metrics.reneged)}
              state={run.metrics.reneged > 0 ? 'warn' : 'good'}
              hint="Web customers who saw the quoted wait and left without ordering. This prices slowness in lost sales rather than seconds (§10.3)."
            />
            <Figure
              explain={explain} label="sat too long" value={pct(run.metrics.quality_breach_rate_multi)}
              state={run.metrics.quality_breach_rate_multi > 0.25 ? 'warn' : 'good'}
              hint={`Drinks in multi-drink orders that waited over 5 minutes on the counter — ice melts, and this is what cohesion exists to reduce (§9.6). Across all orders it is ${pct(run.metrics.quality_breach_rate)}, but a lone drink's wait is just the customer walking over, which no schedule can improve.`}
            />
            {/* Discriminates where p90 cannot: at default demand every policy
                has the same p90, but SJF already spreads this 5.6x. */}
            <Figure
              explain={explain} label="ordered-a-slow-drink penalty"
              value={run.metrics.wait_by_drink_cost.comparable ? `${run.metrics.wait_by_drink_cost.ratio.toFixed(2)}×` : '—'}
              state={
                !run.metrics.wait_by_drink_cost.comparable ? 'warn'
                  : run.metrics.wait_by_drink_cost.ratio > 5 ? 'bad'
                  : run.metrics.wait_by_drink_cost.ratio > 3 ? 'warn' : 'good'
              }
              hint={
                run.metrics.wait_by_drink_cost.comparable
                  ? `How much longer a small order queues before its drinks are started when it ordered slow ones (≥90s, n=${run.metrics.wait_by_drink_cost.dear.orders}) rather than quick ones (≤50s, n=${run.metrics.wait_by_drink_cost.cheap.orders}). Queueing only — a 95s drink takes 95s under any policy. Compare arms at the same demand rather than reading the number alone: the achievable floor falls as the shop fills.`
                  : `Not enough of one kind to compare — ${run.metrics.wait_by_drink_cost.cheap.orders} quick and ${run.metrics.wait_by_drink_cost.dear.orders} slow. Raise demand or widen the run.`
              }
            />
          </dl>

          {/* §10.4's supporting table in full. The row of figures above is the
              at-a-glance read; this is the one that shows all three size
              classes against all three percentiles, and whether the quote the
              customer got was any good. */}
          <MetricGrid metrics={run.metrics} />
        </>
      )}

      {/* §10.5's ablation, below the single run rather than beside it: the run
          above answers "what happened today", this answers "is the scheduler
          the reason". */}
      <section className="mt-10 border-t border-neutral-800 pt-4">
        <div className="flex flex-wrap items-center gap-3 font-mono text-xs">
          <button
            onClick={() => compare()} disabled={comparing}
            className="border border-neutral-700 px-3 py-1 uppercase hover:border-amber-500 disabled:opacity-40"
          >
            {comparing ? 'Comparing…' : 'Compare arms'}
          </button>

          <label className="text-neutral-500">
            over{' '}
            <select
              value={ablationDays} aria-label="days per arm"
              onChange={(e) => setAblationDays(Number(e.target.value))}
              className="border-b border-neutral-700 bg-neutral-950 text-neutral-200 focus:border-amber-500 focus:outline-none"
            >
              <option value={1}>1 day</option>
              <option value={5}>5 days</option>
              <option value={12}>12 days</option>
              <option value={25}>25 days</option>
            </select>
          </label>

          <span className="text-neutral-600">
            runs the same day under each of §6.3's arms, at the seed and demand above
          </span>
        </div>

        {ablation && <AblationBars ablation={ablation} />}
      </section>

      {/* §10.5 #2, its own section for the same reason the ablation is: a
          different question from the run above ("what happened today") and
          from the ablation ("is the scheduler the reason") — this one asks
          "where should the quantum be set". */}
      <section className="mt-10 border-t border-neutral-800 pt-4">
        <div className="flex flex-wrap items-center gap-3 font-mono text-xs">
          <button
            onClick={() => sweepQuantum()} disabled={sweeping}
            className="border border-neutral-700 px-3 py-1 uppercase hover:border-amber-500 disabled:opacity-40"
          >
            {sweeping ? 'Sweeping…' : 'Sweep quantum'}
          </button>

          <label className="text-neutral-500">
            over{' '}
            <select
              value={sweepDays} aria-label="days per point"
              onChange={(e) => setSweepDays(Number(e.target.value))}
              className="border-b border-neutral-700 bg-neutral-950 text-neutral-200 focus:border-amber-500 focus:outline-none"
            >
              <option value={1}>1 day</option>
              <option value={5}>5 days</option>
              <option value={12}>12 days</option>
              <option value={25}>25 days</option>
            </select>
          </label>

          <span className="text-neutral-600">
            runs the same day at ten quantum values, 30s–400s, at the seed and demand above (§10.5)
          </span>
        </div>

        {sweep && <QuantumSweepChart sweep={sweep} />}
      </section>

      {/* §10.5 #3, its own section for the same reason the two above are: a
          different question again — not "what happened today" or "where
          should a knob sit", but "how many baristas does each hour need". */}
      <section className="mt-10 border-t border-neutral-800 pt-4">
        <div className="flex flex-wrap items-center gap-3 font-mono text-xs">
          <button
            onClick={() => staff()} disabled={staffingBusy}
            className="border border-neutral-700 px-3 py-1 uppercase hover:border-amber-500 disabled:opacity-40"
          >
            {staffingBusy ? 'Staffing…' : 'Build staffing curve'}
          </button>

          <label className="text-neutral-500">
            over{' '}
            <select
              value={staffingDays} aria-label="days per station count"
              onChange={(e) => setStaffingDays(Number(e.target.value))}
              className="border-b border-neutral-700 bg-neutral-950 text-neutral-200 focus:border-amber-500 focus:outline-none"
            >
              <option value={1}>1 day</option>
              <option value={5}>5 days</option>
              <option value={12}>12 days</option>
              <option value={25}>25 days</option>
            </select>
          </label>

          <label className="text-neutral-500">
            target p90{' '}
            <select
              value={target} aria-label="target p90"
              onChange={(e) => setTarget(Number(e.target.value))}
              className="border-b border-neutral-700 bg-neutral-950 text-neutral-200 focus:border-amber-500 focus:outline-none"
            >
              <option value={300}>5 min</option>
              <option value={600}>10 min</option>
              <option value={900}>15 min</option>
            </select>
          </label>

          <span className="text-neutral-600">
            runs each open hour at 1–8 stations, whole day, at the seed and demand above (§10.5)
          </span>
        </div>

        {staffing && <StaffingCurveTable curve={staffing} />}
      </section>

      {/* §10.5 #4, its own section for the same reason the three above are: a
          different question again — not "what happened today", "where should
          a knob sit", or "how many baristas", but "how much demand can this
          config actually take". No demand control here — this experiment
          sweeps demand itself, so the slider above does not apply to it. */}
      <section className="mt-10 border-t border-neutral-800 pt-4">
        <div className="flex flex-wrap items-center gap-3 font-mono text-xs">
          <button
            onClick={() => findBreakingPoint()} disabled={breaking}
            className="border border-neutral-700 px-3 py-1 uppercase hover:border-amber-500 disabled:opacity-40"
          >
            {breaking ? 'Finding…' : 'Find breaking point'}
          </button>

          <label className="text-neutral-500">
            over{' '}
            <select
              value={breakingDays} aria-label="days per demand point"
              onChange={(e) => setBreakingDays(Number(e.target.value))}
              className="border-b border-neutral-700 bg-neutral-950 text-neutral-200 focus:border-amber-500 focus:outline-none"
            >
              <option value={1}>1 day</option>
              <option value={5}>5 days</option>
              <option value={12}>12 days</option>
              <option value={25}>25 days</option>
            </select>
          </label>

          <label className="text-neutral-500">
            target p90{' '}
            <select
              value={breakingTarget} aria-label="target p90 for breaking point"
              onChange={(e) => setBreakingTarget(Number(e.target.value))}
              className="border-b border-neutral-700 bg-neutral-950 text-neutral-200 focus:border-amber-500 focus:outline-none"
            >
              <option value={300}>5 min</option>
              <option value={600}>10 min</option>
              <option value={900}>15 min</option>
            </select>
          </label>

          <span className="text-neutral-600">
            raises demand from 0.5× to 3× at {stations} stations until overall p90 crosses target (§10.5)
          </span>
        </div>

        {breakingPoint && <BreakingPointChart result={breakingPoint} />}
      </section>
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
  quiet,
}: {
  run: SimulationRun
  policy: string
  previous: { run: SimulationRun; policy: string } | null
  quiet: boolean
}) {
  const small = run.metrics.by_size_class['1-2'].p90
  const large = run.metrics.by_size_class['7+'].p90
  const against =
    previous && previous.policy !== policy && previous.run.seed === run.seed ? previous : null
  const delta = against ? small - against.run.metrics.by_size_class['1-2'].p90 : null

  return (
    <section className="mb-3 border-l-2 border-amber-600 pl-3 font-mono text-sm text-neutral-300">
      <p>
        <strong className="text-neutral-100">1–2 drinks</strong>{' '}
        <strong className="tabular-nums text-amber-500">{small}s</strong> at p90 ·{' '}
        <strong className="text-neutral-100">7+</strong>{' '}
        <span className="tabular-nums">{large}s</span>
        {delta !== null && (
          <span className={delta < 0 ? 'text-emerald-400' : 'text-orange-400'}>
            {' '}· {Math.abs(delta).toFixed(1)}s {delta < 0 ? 'faster' : 'slower'} than{' '}
            {against?.policy.toUpperCase()} on the same day
          </span>
        )}
      </p>

      {/* Below saturation every policy dispatches almost the same order, so the
          panel must not invite a comparison it cannot support (§10.3). */}
      {quiet && (
        <p className="mt-0.5 text-xs text-neutral-500">
          Too quiet to compare arms — raise demand or drop a station.
        </p>
      )}
    </section>
  )
}

/**
 * §10.6's "Apply to store" — the only path from the dashboard's config rail
 * to `stores.scheduler_config`. Thin by design: today the rail only exposes
 * `policy`, so that is the only field this writes (ADR-0022). `rr`/`sjf`
 * never reach the confirm step — `UpdateSchedulerConfig::SCHEMA` refuses
 * them, and disabling the button here says so before the request round-trip
 * does.
 *
 * "Never let dashboard state silently become production state" (§10.6):
 * `confirming` is a required stop between clicking and writing, and shows
 * the diff — live policy versus what the rail is set to — rather than
 * asking for blind trust in a button label.
 */
function ApplyToStore({
  policy, liveConfig, confirming, applying, error, onRequestApply, onCancel, onConfirm,
}: {
  policy: Policy
  liveConfig: SchedulerConfig | null
  confirming: boolean
  applying: boolean
  error: string | null
  onRequestApply: () => void
  onCancel: () => void
  onConfirm: () => void
}) {
  const simulatorOnly = policy === 'rr' || policy === 'sjf'
  const matchesLive = liveConfig !== null && liveConfig.policy === policy

  if (confirming) {
    return (
      <div className="flex items-center gap-2 border border-amber-700 px-2 py-1 font-mono text-xs">
        <span className="text-amber-500">
          apply policy: {liveConfig?.policy} → {policy}?
        </span>
        <button
          onClick={onConfirm} disabled={applying}
          className="border border-amber-600 bg-amber-600 px-2 py-0.5 uppercase text-neutral-950 hover:bg-amber-500 disabled:opacity-40"
        >
          {applying ? 'Applying…' : 'Confirm'}
        </button>
        <button
          onClick={onCancel} disabled={applying}
          className="text-neutral-500 hover:text-neutral-300 disabled:opacity-40"
        >
          cancel
        </button>
        {error && <span className="text-rose-500">{error}</span>}
      </div>
    )
  }

  return (
    <div className="flex items-center gap-2 font-mono text-xs">
      <span className="text-neutral-600" title="What the store is actually running right now">
        live {liveConfig ? liveConfig.policy.toUpperCase() : '…'}
      </span>
      <button
        onClick={onRequestApply}
        disabled={simulatorOnly || liveConfig === null || matchesLive}
        title={
          simulatorOnly ? `${policy.toUpperCase()} is simulator-only and can never run live`
            : liveConfig === null ? 'Reading live config…'
              : matchesLive ? 'Already live'
                : `Write policy: ${policy} to the store`
        }
        className="border border-neutral-700 px-2 py-0.5 uppercase text-neutral-500 hover:border-amber-500 hover:text-neutral-300 disabled:opacity-30 disabled:hover:border-neutral-700 disabled:hover:text-neutral-500"
      >
        Apply to store
      </button>
    </div>
  )
}

/** A ribbon is unreadable without a key to what its shapes mean. */
function Legend() {
  return (
    <ul className="mt-3 ml-24 flex flex-wrap gap-x-5 font-mono text-[10px] text-neutral-600">
      <li className="flex items-center gap-1.5">
        <span className="flex gap-0.5">
          <span className="h-2.5 w-2.5 rounded-full" style={{ background: 'hsl(275 62% 58%)' }} />
          <span className="h-2.5 w-2.5 rounded-full" style={{ background: 'hsl(275 62% 58%)' }} />
        </span>
        same colour = same order
      </li>
      <li className="flex items-center gap-1.5">
        <span className="h-2.5 w-5 rounded-full border-2 border-dashed border-white/70" style={{ background: 'hsl(50 62% 58%)' }} />
        remake
      </li>
      <li>rows are stations · width is how long a drink took</li>
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
  label, value, hint, explain, accent = false, state,
}: {
  label: string; value: string; hint: string; explain: boolean
  accent?: boolean; state?: keyof typeof STATE_COLOUR
}) {
  const colour = state ? STATE_COLOUR[state] : accent ? 'text-amber-500' : 'text-neutral-200'

  return (
    <div className="border-t border-neutral-800 pt-1" title={explain ? undefined : hint}>
      <dt className="text-[10px] tracking-wider text-neutral-600 uppercase">{label}</dt>
      <dd className={`text-base tabular-nums ${colour}`}>{value}</dd>
      {explain && <p className="mt-0.5 text-[10px] leading-snug text-neutral-500">{hint}</p>}
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

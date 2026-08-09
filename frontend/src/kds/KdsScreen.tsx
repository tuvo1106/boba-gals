import { useCallback, useState } from 'react'
import { apiPost } from '../api/client'
import { useKitchen, type LastAction } from './useKitchen'
import { formatWait } from './format'
import { clearSession, readSession, writeSession } from './session'
import type { KdsItem, KdsSession } from '../api/types'

/**
 * The kitchen display (DESIGN.md §9.4).
 *
 * "Layout: a single vertical lane of drink cards, largest at top." Built for a
 * barista with wet hands looking at a screen across a counter, not for a
 * developer at a laptop — so targets are large, text is large, and there is
 * nothing on it that is not one of §9.4's five listed things.
 *
 * **No confirmation dialogs** (§9.4). One tap starts a drink, one tap finishes
 * it. The escape hatch is the 60-second undo, which is why that affordance is
 * pinned rather than tucked away.
 */
export function KdsScreen() {
  // Restored from the tab's own storage, so a refresh — or a tablet that
  // reloads itself overnight — does not drop the shift (`session.ts` explains
  // why it is sessionStorage rather than a cookie).
  const [session, setSession] = useState<KdsSession | null>(readSession)

  const signIn = useCallback((next: KdsSession) => {
    writeSession(next)
    setSession(next)
  }, [])

  const signOut = useCallback(() => {
    clearSession()
    setSession(null)
  }, [])

  if (session === null) return <SignIn onSignedIn={signIn} />

  return <Kitchen session={session} onSignedOut={signOut} />
}

function Kitchen({ session, onSignedOut }: { session: KdsSession; onSignedOut: () => void }) {
  const { queue, connection, error, oldestWaitingSeconds, lastAction, start, finish, undo } =
    useKitchen(session, onSignedOut)

  return (
    <main className="min-h-screen bg-neutral-950 text-neutral-100">
      {/* "Show queue depth and the oldest waiting time in the header. Nothing
          else." — §9.4, and it means it. */}
      <header className="flex items-center gap-6 border-b border-neutral-800 px-6 py-3">
        <Stat label="waiting" value={queue ? String(queue.depth) : '—'} />
        {/* Counts forward from the last snapshot rather than sitting still
            between them. A quiet store broadcasts only on the 30s idle tick,
            so a frozen number is how a drink gets forgotten (§9.4). */}
        <Stat
          label="oldest"
          value={queue ? formatWait(oldestWaitingSeconds) : '—'}
          warn={oldestWaitingSeconds > 600}
        />

        <span className="ml-auto flex items-center gap-3 font-mono text-xs text-neutral-500">
          <span className={connection === 'live' ? 'text-emerald-400' : 'text-orange-400'}>
            {connection === 'live' ? '● live' : connection === 'offline' ? '● offline' : '● connecting'}
          </span>
          {session.station.name} · {session.barista.name}
          <button onClick={onSignedOut} className="underline hover:text-neutral-300">sign out</button>
        </span>
      </header>

      {error && <p role="alert" className="bg-rose-950 px-6 py-2 font-mono text-sm text-rose-300">{error}</p>}

      <div className="mx-auto max-w-3xl px-6 py-5">
        <section aria-label="Making">
          {queue?.in_progress.length ? (
            <ul className="flex flex-col gap-3">
              {queue.in_progress.map((item, index) => (
                <DrinkCard key={item.id} item={item} lead={index === 0} onFinish={() => finish(item)} />
              ))}
            </ul>
          ) : (
            <button
              onClick={start}
              disabled={!queue?.depth}
              className="w-full rounded-lg border-2 border-dashed border-neutral-700 py-10 text-2xl font-semibold text-neutral-400 disabled:opacity-40 hover:border-amber-500 hover:text-amber-500"
            >
              {queue?.depth ? 'Start next drink' : 'Nothing waiting'}
            </button>
          )}
        </section>

        {/* "Always render a Next up section (3 items) so a barista can
            pre-stage cups and toppings. This is where real throughput comes
            from." — §9.4. Always, so it never moves. */}
        <section aria-label="Next up" className="mt-8">
          <h2 className="mb-2 font-mono text-xs tracking-widest text-neutral-600 uppercase">Next up</h2>
          {queue?.next_up.length ? (
            <ul className="flex flex-col gap-2">
              {queue.next_up.map((item) => (
                <li key={item.id} className="flex items-center gap-3 rounded border border-neutral-800 px-4 py-2.5">
                  <Tokens item={item} muted />
                  <span className="ml-auto font-mono text-xs text-neutral-600">{item.pickup_code}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="font-mono text-sm text-neutral-700">Queue is empty</p>
          )}
        </section>
      </div>

      {lastAction && <UndoBar action={lastAction} onUndo={undo} />}
    </main>
  )
}

/**
 * "Each card shows: drink name, options as bold short tokens, pickup code, and
 * position within its order (2 of 5)." (§9.4)
 *
 * The position matters more than it looks: it is how a barista knows the drink
 * in their hand belongs to a larger order being interleaved by the scheduler,
 * rather than a single order they are somehow making out of sequence.
 */
function DrinkCard({ item, lead, onFinish }: { item: KdsItem; lead: boolean; onFinish: () => void }) {
  return (
    <li
      className={`rounded-lg border-2 ${lead ? 'p-6' : 'p-4 opacity-90'} ${item.remake ? 'border-amber-500 bg-amber-950/30' : 'border-neutral-700 bg-neutral-900'}`}
    >
      <div className="flex items-start gap-4">
        <div className="min-w-0">
          {/* Remakes carry a distinct *persistent* marker (§9.4) — not a flash
              or a toast, because the barista who needs it may not be the one
              who was standing there when it was created. */}
          {item.remake && (
            <p className="mb-1 font-mono text-xs font-bold tracking-widest text-amber-400 uppercase">Remake</p>
          )}
          <Tokens item={item} lead={lead} />
        </div>

        <div className="ml-auto shrink-0 text-right">
          <p className={`font-mono tabular-nums text-neutral-300 ${lead ? 'text-2xl' : 'text-lg'}`}>{item.pickup_code}</p>
          {item.order_size > 1 && (
            <p className="font-mono text-sm text-neutral-500">
              {item.sequence} of {item.order_size}
            </p>
          )}
        </div>
      </div>

      {/* One tap. No confirmation dialog (§9.4). */}
      <button
        onClick={onFinish}
        className={`mt-4 w-full rounded bg-emerald-600 font-semibold text-neutral-950 hover:bg-emerald-500 ${lead ? 'py-5 text-2xl' : 'py-3 text-lg'}`}
      >
        Done
      </button>
    </li>
  )
}

/**
 * Options as "bold short tokens — `50%`, `LESS ICE`, `+PEARL`" (§9.4).
 *
 * The label arrives as one comma-joined string from the server, so it is split
 * back apart here: the drink name leads at full size, and each option becomes a
 * chip that can be read at a glance from across a counter.
 */
function Tokens({ item, muted = false, lead = true }: { item: KdsItem; muted?: boolean; lead?: boolean }) {
  const [name, ...options] = item.label.split(',').map((part) => part.trim())

  return (
    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
      <span className={muted ? 'text-base text-neutral-300' : lead ? 'text-3xl font-semibold' : 'text-xl font-semibold'}>
        {name}
      </span>
      {options.map((option) => (
        <span
          key={option}
          className={`rounded bg-neutral-800 px-1.5 py-0.5 font-mono font-bold tracking-wide uppercase ${muted ? 'text-[10px] text-neutral-400' : 'text-xs text-neutral-200'}`}
        >
          {option}
        </span>
      ))}
    </div>
  )
}

/**
 * §9.4: "Undo is the escape hatch: a 60-second undo affordance on the last
 * action." Pinned to the bottom because it is the only thing standing between a
 * mistap and a drink marked done that nobody made — there being no confirmation
 * dialog to catch it first.
 */
function UndoBar({ action, onUndo }: { action: LastAction; onUndo: () => void }) {
  return (
    <div className="fixed inset-x-0 bottom-0 flex items-center gap-4 border-t border-neutral-700 bg-neutral-900 px-6 py-3">
      <span className="font-mono text-sm text-neutral-300">
        {action.kind === 'finished' ? 'Finished' : 'Started'} {action.item.label.split(',')[0]}
      </span>
      <span className="font-mono text-xs tabular-nums text-neutral-500">{action.secondsLeft}s</span>
      <button
        onClick={onUndo}
        className="ml-auto rounded border border-neutral-600 px-5 py-2 font-semibold hover:border-amber-500 hover:text-amber-500"
      >
        Undo
      </button>
    </div>
  )
}

function Stat({ label, value, warn = false }: { label: string; value: string; warn?: boolean }) {
  return (
    <div>
      <p className="font-mono text-[10px] tracking-widest text-neutral-600 uppercase">{label}</p>
      <p className={`font-mono text-2xl tabular-nums ${warn ? 'text-orange-400' : 'text-neutral-100'}`}>{value}</p>
    </div>
  )
}

/** Barista PIN sign-in (§13.3). The token is held in memory only — a KDS tablet
 *  is a shared device, and a token in localStorage outlives the shift. */
function SignIn({ onSignedIn }: { onSignedIn: (session: KdsSession) => void }) {
  const [stationId, setStationId] = useState('')
  const [pin, setPin] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      onSignedIn(
        await apiPost<KdsSession>('/kds/session', {
          station_id: Number(stationId),
          barista_pin: pin,
        }),
      )
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Sign in failed')
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-neutral-950 text-neutral-100">
      <form onSubmit={submit} className="flex w-72 flex-col gap-4">
        <h1 className="font-mono text-sm tracking-widest text-neutral-500 uppercase">Kitchen display</h1>

        <label className="flex flex-col gap-1 font-mono text-xs text-neutral-500">
          station
          <input
            type="number" value={stationId} onChange={(e) => setStationId(e.target.value)}
            required aria-label="station"
            className="rounded border border-neutral-700 bg-transparent px-3 py-2 text-lg text-neutral-100 focus:border-amber-500 focus:outline-none"
          />
        </label>

        <label className="flex flex-col gap-1 font-mono text-xs text-neutral-500">
          pin
          <input
            type="password" inputMode="numeric" value={pin} onChange={(e) => setPin(e.target.value)}
            required aria-label="pin"
            className="rounded border border-neutral-700 bg-transparent px-3 py-2 text-lg tracking-widest text-neutral-100 focus:border-amber-500 focus:outline-none"
          />
        </label>

        {error && <p role="alert" className="font-mono text-sm text-rose-400">{error}</p>}

        <button
          type="submit" disabled={busy}
          className="rounded bg-amber-600 py-3 font-semibold text-neutral-950 disabled:opacity-40 hover:bg-amber-500"
        >
          {busy ? 'Signing in…' : 'Start shift'}
        </button>
      </form>
    </main>
  )
}

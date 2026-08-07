import { formatEta, formatReadySince } from './format'
import { useBoard } from './useBoard'
import type { MakingRow, ReadyRow } from '../api/types'

/**
 * The customer board (§9.5): two columns, high contrast, readable at 15 feet.
 *
 * Privacy is locked (§3): first name and pickup code, nothing else. Two Sarahs
 * are told apart by their codes — never by adding a surname initial.
 *
 * Type is sized for distance rather than for a laptop. The smallest thing on
 * this screen is the drink list, and it is still 24px.
 */
export function BoardScreen() {
  const { making, ready, connection } = useBoard()

  return (
    <main className="min-h-screen bg-neutral-950 text-neutral-50 p-8">
      <div className="grid grid-cols-2 gap-8 h-full">
        <Column title="Making" count={making.length}>
          {making.map((row) => (
            <MakingCard key={row.pickup_code} row={row} />
          ))}
        </Column>

        <Column title="Ready" count={ready.length}>
          {ready.map((row) => (
            <ReadyCard key={row.pickup_code} row={row} />
          ))}
        </Column>
      </div>

      {/* Staff-facing, deliberately quiet. A customer should never be asked to
          care that a websocket dropped; a barista walking past should be able
          to tell at a glance whether the board is stale (§9.5). */}
      {connection !== 'live' && (
        <p className="fixed bottom-4 right-6 text-lg text-neutral-600" role="status">
          {connection === 'connecting' ? 'Connecting…' : 'Reconnecting…'}
        </p>
      )}
    </main>
  )
}

function Column({
  title,
  count,
  children,
}: {
  title: string
  count: number
  children: React.ReactNode
}) {
  return (
    <section aria-label={title}>
      <h2 className="text-4xl font-semibold tracking-tight text-neutral-400 uppercase mb-6">
        {title}
      </h2>

      {count === 0 ? (
        <p className="text-3xl text-neutral-700">Nothing right now</p>
      ) : (
        <ul className="space-y-4">{children}</ul>
      )}
    </section>
  )
}

function MakingCard({ row }: { row: MakingRow }) {
  return (
    <li className="rounded-xl bg-neutral-900 px-6 py-5">
      <div className="flex items-baseline justify-between gap-6">
        <span className="text-5xl font-semibold">{row.first_name ?? 'Guest'}</span>
        <span className="text-4xl font-mono text-neutral-400 tabular-nums">{row.pickup_code}</span>
      </div>

      <p className="mt-2 text-2xl text-neutral-500 truncate">{row.items.join(' · ')}</p>
      <p className="mt-1 text-3xl text-neutral-300">{formatEta(row.eta_seconds)}</p>
    </li>
  )
}

/**
 * "Ready — first name, pickup code, visually dominant." (§9.5) The size
 * difference is the point: a customer scanning from across the room should find
 * their name in this column without reading the other one.
 */
function ReadyCard({ row }: { row: ReadyRow }) {
  return (
    <li className="rounded-xl bg-emerald-500 px-6 py-5 text-neutral-950">
      <div className="flex items-baseline justify-between gap-6">
        <span className="text-6xl font-bold">{row.first_name ?? 'Guest'}</span>
        <span className="text-5xl font-mono font-bold tabular-nums">{row.pickup_code}</span>
      </div>

      <p className="mt-2 text-2xl font-medium text-emerald-900">
        {formatReadySince(row.ready_since_seconds)}
      </p>
    </li>
  )
}

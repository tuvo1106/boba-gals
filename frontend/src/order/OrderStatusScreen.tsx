import { formatPrice, formatProgress, formatWaitRange } from './money'
import { tapTarget, type OrderingMode } from './mode'
import { useOrderStatus } from './useOrderStatus'
import type { DrinkStatus, OrderStatus, PlacedOrder } from '../api/types'

/**
 * What a customer looks at while they wait (§9.2, §9.3).
 *
 * The pickup code is the largest thing on the screen because it is what the
 * customer is asked for at the counter, and because it is what the board shows
 * next to their name (§3, locked).
 *
 * Drinks are listed individually rather than rolled into one bar. §6 interleaves
 * one order's drinks with everyone else's, so a five-drink order really is
 * three-fifths done — a single progress bar would sit still for eight minutes
 * and then jump.
 */
export function OrderStatusScreen({
  pickupCode,
  seed = null,
  mode,
  onStartOver,
}: {
  pickupCode: string
  seed?: PlacedOrder | null
  mode: OrderingMode
  onStartOver?: () => void
}) {
  const { order, progress, error } = useOrderStatus(pickupCode, seed)

  if (error) {
    return (
      <main className="grid min-h-screen place-items-center bg-neutral-950 px-6 text-neutral-100">
        <p role="alert" className="text-center text-xl text-neutral-400">
          {error}
        </p>
      </main>
    )
  }

  const ready = progress?.status === 'ready'
  const made = progress?.items.filter((item) => item.status === 'finished').length ?? 0
  const progressLine = formatProgress(made, progress?.items.length ?? 0)

  return (
    <main className="min-h-screen bg-neutral-950 px-6 py-10 text-neutral-100">
      <div className="mx-auto flex max-w-xl flex-col gap-8">
        <section
          aria-label="Pickup code"
          className={`rounded-2xl border-2 px-6 py-8 text-center ${
            ready ? 'border-emerald-500 bg-emerald-950/30' : 'border-neutral-800 bg-neutral-900'
          }`}
        >
          <p className="font-mono text-xs tracking-widest text-neutral-500 uppercase">
            Pickup code
          </p>
          <p className="mt-1 font-mono text-6xl font-bold tracking-widest tabular-nums">
            {pickupCode}
          </p>

          <p className={`mt-4 text-xl ${ready ? 'text-emerald-300' : 'text-neutral-300'}`}>
            {headline(progress?.status)}
          </p>

          {/* Progress leads, the time follows in smaller type. A count of
              finished drinks only ever goes up; the estimate genuinely moves,
              because §6.1 shares capacity with orders arriving behind this one.
              One monotonic thing to watch is what makes the other tolerable. */}
          {progressLine && !ready && (
            <p className="mt-2 text-lg text-neutral-200">{progressLine}</p>
          )}

          {/* The estimate disappears once the drinks are made — a countdown next
              to "Ready" is worse than no countdown. */}
          {progress && !ready && (
            <p className="mt-1 font-mono text-sm text-neutral-500">
              {formatWaitRange(progress.etaSeconds)}
            </p>
          )}
        </section>

        <section aria-label="Drinks" className="flex flex-col gap-2">
          {(progress?.items ?? []).map((item) => (
            <div
              key={item.id}
              className="flex items-center gap-4 rounded-lg border border-neutral-800 px-4 py-3"
            >
              <span className={item.status === 'finished' ? 'text-neutral-500' : ''}>
                {item.label}
              </span>
              <span
                className={`ml-auto font-mono text-xs tracking-widest uppercase ${drinkTone(item.status)}`}
              >
                {drinkLabel(item.status)}
              </span>
            </div>
          ))}
        </section>

        {order && (
          <p className="font-mono text-sm text-neutral-500">
            {formatPrice(order.total_cents)} — pay at the counter
          </p>
        )}

        {onStartOver && (
          <button
            onClick={onStartOver}
            className={`rounded-lg border border-neutral-700 px-6 text-neutral-300 hover:border-neutral-500 ${tapTarget(mode)}`}
          >
            Start a new order
          </button>
        )}
      </div>
    </main>
  )
}

function headline(status: OrderStatus | undefined): string {
  switch (status) {
    case 'ready':
      return 'Ready — come and collect it'
    case 'partially_ready':
      return 'Nearly there'
    case 'in_progress':
      return 'Being made now'
    case 'picked_up':
      return 'Collected'
    case 'cancelled':
      return 'Cancelled'
    default:
      return 'In the queue'
  }
}

function drinkLabel(status: DrinkStatus): string {
  switch (status) {
    case 'finished':
      return 'done'
    case 'in_progress':
      return 'making'
    case 'cancelled':
      return 'cancelled'
    // A failed drink has already produced a remake row the customer can see, so
    // saying "failed" here would mean showing them two rows for one drink and
    // explaining neither.
    case 'failed':
      return 'remaking'
    default:
      return 'waiting'
  }
}

function drinkTone(status: DrinkStatus): string {
  if (status === 'finished') return 'text-emerald-400'
  if (status === 'in_progress') return 'text-amber-400'

  return 'text-neutral-600'
}

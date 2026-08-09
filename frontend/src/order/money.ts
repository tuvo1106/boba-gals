/**
 * Prices are integer cents everywhere (§4.1) and are only ever turned into
 * strings here. Doing the arithmetic in cents and formatting at the edge is
 * what keeps a 5.50 + 0.75 cart from totalling 6.249999999999999.
 *
 * @param cents e.g. 1175
 * @returns e.g. "$11.75"
 */
export function formatPrice(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`
}

/** A price delta on an option, blank when it costs nothing. */
export function formatPriceDelta(cents: number): string {
  return cents === 0 ? '' : `+${formatPrice(cents)}`
}

/**
 * The quoted wait, as a range rather than a point (§7.3).
 *
 * A single number invites being read as a promise, and this one genuinely
 * moves: the scheduler shares capacity between orders (§6.1), so work arriving
 * *behind* a customer can push their estimate out. Measured on the simulator at
 * §10.3's peak demand, a small order that gets overtaken at all loses a p90 of
 * 257 seconds — which is a visible jump on a four-minute wait.
 *
 * A range absorbs the ordinary case without the number visibly going backwards.
 * It is also more truthful about how good §7.3's estimate actually is: the
 * projection is honest to the second, but a customer reading "4:37" believes it
 * to the second, and it is not that good.
 *
 * The width is deliberately *not* wide enough to swallow the p90 overtake —
 * "4–9 min" is useless. It covers the common case and lets the rest move, which
 * §7.3 requires: a board that never revises is a board that lies, and
 * "the difference between a board customers trust and one they learn to ignore".
 */
export function formatWaitRange(seconds: number): string {
  if (seconds <= 0) return 'Any moment now'

  const low = Math.max(1, Math.round(seconds / 60))
  const high = Math.max(low + 1, Math.ceil(low * 1.4))

  return `${low}–${high} min`
}

/**
 * "2 of 5 made" — the part of the estimate that cannot go backwards.
 *
 * This leads, and the time follows in smaller type. §6 interleaves an order's
 * drinks with everyone else's, so a part-made order is genuinely part-made, and
 * a count of finished drinks only ever moves forward. Giving a customer one
 * monotonic signal to watch is what makes a wobbling time tolerable beside it.
 *
 * @returns null for a single-drink order — "1 of 1" is noise
 */
export function formatProgress(made: number, total: number): string | null {
  if (total <= 1) return null

  return `${made} of ${total} made`
}

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
 * The quoted wait, rounded to whole minutes (§7.3).
 *
 * Deliberately coarse. The projection is honest to the second but a customer
 * reading "4:37" believes it to the second, and §7.3's estimate is not that
 * good — a drink running long moves it by more than the precision implies.
 */
export function formatWaitMinutes(seconds: number): string {
  if (seconds <= 0) return 'about a minute'

  const minutes = Math.max(1, Math.round(seconds / 60))

  return minutes === 1 ? 'about a minute' : `about ${minutes} minutes`
}

/**
 * Minutes and seconds — a barista reads "7:20", never "440 seconds" (§9.4).
 *
 * Falls back to hours past sixty minutes. "1204:00" is technically correct and
 * completely unreadable, and the case is reachable: a drink queued before close
 * and still waiting the next morning is exactly the kind of thing the oldest-wait
 * figure exists to make impossible to miss.
 */
export function formatWait(seconds: number): string {
  if (seconds <= 0) return '0:00'
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`

  const minutes = Math.floor(seconds / 60)

  return `${minutes}:${String(seconds % 60).padStart(2, '0')}`
}

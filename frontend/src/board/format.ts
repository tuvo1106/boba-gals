/**
 * §9.5: "ETA in minutes (never seconds; false precision reads as a lie). Show
 * `Almost ready` under 2 minutes."
 */
export const ALMOST_READY_SECONDS = 120

export function formatEta(seconds: number): string {
  if (seconds <= ALMOST_READY_SECONDS) return 'Almost ready'

  return `${Math.ceil(seconds / 60)} min`
}

/**
 * How long a name has been sitting in the Ready column. Rounded down to whole
 * minutes for the same reason ETA is: a counter ticking by the second turns a
 * board into something people watch instead of glance at.
 */
export function formatReadySince(seconds: number): string {
  if (seconds < 60) return 'Just now'

  return `${Math.floor(seconds / 60)} min ago`
}

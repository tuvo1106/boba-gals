/**
 * Simulated seconds are relative to a 10:00 open (§10.3's arrival profile), and
 * every reader of this dashboard thinks in shop hours rather than seconds since
 * open. Shared so the axis and the scrubber cannot drift apart.
 */
export const OPENS_AT = 10

export function shopClock(seconds: number): string {
  const total = Math.round(seconds)
  const h = OPENS_AT + Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)

  return `${h}:${String(m).padStart(2, '0')}`
}

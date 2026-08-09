/**
 * Kiosk mode is a runtime flag, not a fork (§9.3). One React codebase, one
 * build; the route decides which set of rules applies.
 *
 * What actually differs in this build:
 *
 * | | Kiosk | Web |
 * |---|---|---|
 * | Hit targets | min 64px | min 44px |
 * | Name entry | first name | first name + phone for SMS (§9.7) |
 * | `source` on the order | `kiosk` | `web` |
 *
 * Still to come, and sequenced there by §12 step 8 rather than overlooked: the
 * 90-second idle reset, the on-screen keyboard, order-ahead `promised_at`, and
 * the offline refusal that polls `/health` (§9.3, locked in §3).
 */
export type OrderingMode = 'kiosk' | 'web'

/**
 * §9.3's minimum hit target for the mode. A kiosk is tapped by someone standing
 * up, often with a bag in the other hand; a phone is held.
 *
 * @param mode the surface this control is rendered on
 * @returns Tailwind classes sizing the control, never smaller than the minimum
 */
export function tapTarget(mode: OrderingMode): string {
  return mode === 'kiosk' ? 'min-h-16 text-lg' : 'min-h-11'
}

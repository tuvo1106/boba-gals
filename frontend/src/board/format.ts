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

/** How many distinct drink names fit before the line stops being scannable. */
export const NAMED_DRINKS = 2

/**
 * The drink line on a Making card.
 *
 * Three things a raw `items.join(' · ')` got wrong on a real board:
 *
 * 1. **Options are noise here.** The label is the denormalized build string
 *    (§4.1) — "Classic Milk Tea, 50%, Less ice, Boba pearls" — which is what
 *    the barista needs (§9.4) and not what a customer does. One drink with
 *    toppings filled the line on its own. Only the name survives.
 * 2. **Repeats are a count, not a list.** The ordering app has a quantity
 *    control, so six of one drink is now a normal order, and
 *    "Classic Milk Tea · Classic Milk Tea · …" tells nobody anything.
 * 3. **Long orders overflow rather than summarise.** §2 exists for the
 *    fifteen-drink catering order; the board has one line for it.
 *
 * The point of this line is a customer confirming these are *their* drinks
 * from fifteen feet, not reading the order back.
 *
 * @param items labels as `BoardView` sends them (§9.2)
 * @returns e.g. `"Classic Milk Tea ×3 · Thai Tea"`, `"Taro Slush +2 more"`
 */
export function summariseDrinks(items: string[]): string {
  const counts = new Map<string, number>()

  for (const label of items) {
    // The name is everything before the first option (§4.1's label format).
    const name = label.split(',')[0].trim()
    counts.set(name, (counts.get(name) ?? 0) + 1)
  }

  const named = [ ...counts.entries() ]
    .slice(0, NAMED_DRINKS)
    .map(([ name, count ]) => (count > 1 ? `${name} ×${count}` : name))

  const remaining = [ ...counts.values() ].slice(NAMED_DRINKS).reduce((sum, n) => sum + n, 0)

  return remaining > 0 ? `${named.join(' · ')} +${remaining} more` : named.join(' · ')
}

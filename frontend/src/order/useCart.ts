import { useCallback, useMemo, useRef, useState } from 'react'
import type { MenuItem, MenuOption } from '../api/types'

/**
 * One drink in the cart.
 *
 * `key` exists because two identical drinks are two lines, not a quantity of
 * two: §2 makes the drink the unit of work, and a customer removing one of
 * their two Thai Teas must not remove both.
 */
export interface CartLine {
  key: number
  item: MenuItem
  options: MenuOption[]
  priceCents: number
}

export interface Cart {
  lines: CartLine[]
  totalCents: number
  add: (item: MenuItem, options: MenuOption[]) => void
  remove: (key: number) => void
  clear: () => void
}

/**
 * The ordering cart (§9.3).
 *
 * In memory only, and deliberately: §9.3's offline rule preserves the cart
 * across a blip so a customer does not lose an in-progress order, but there is
 * no local queue and no optimistic accept. Persisting it to storage would
 * outlive the kiosk's idle reset and hand the next customer someone else's
 * drinks.
 *
 * The price of a line is frozen from the menu the customer is looking at. The
 * server recomputes it from its own menu when the order is placed (§4.1) — this
 * copy is what the cart displays, never what anyone is charged.
 */
export function useCart(): Cart {
  const [lines, setLines] = useState<CartLine[]>([])
  // A ref rather than state, and read *outside* the updater: StrictMode invokes
  // state updaters twice, so allocating the key inside one would either
  // double-count or make the updater impure.
  const nextKey = useRef(1)

  const add = useCallback((item: MenuItem, options: MenuOption[]) => {
    const key = nextKey.current++

    setLines((current) => [
      ...current,
      {
        key,
        item,
        options,
        priceCents: item.price_cents + options.reduce((sum, o) => sum + o.price_cents, 0),
      },
    ])
  }, [])

  const remove = useCallback((key: number) => {
    setLines((current) => current.filter((line) => line.key !== key))
  }, [])

  const clear = useCallback(() => setLines([]), [])

  const totalCents = useMemo(
    () => lines.reduce((sum, line) => sum + line.priceCents, 0),
    [lines],
  )

  return { lines, totalCents, add, remove, clear }
}

/** The shape `POST /orders` wants: menu item plus the chosen option ids. */
export function toOrderItems(lines: CartLine[]) {
  return lines.map((line) => ({
    menu_item_id: line.item.id,
    option_ids: line.options.map((option) => option.id),
  }))
}

import { useCallback, useMemo, useRef, useState } from 'react'
import type { MenuItem, MenuOption } from '../api/types'

/**
 * One configuration of a drink, and how many of it.
 *
 * Quantity is a cart affordance, not a scheduling one. §2 keeps the drink as
 * the unit of work, so `toOrderItems` expands a line of three into three
 * entries and the server creates three `OrderItem` rows the scheduler
 * interleaves independently — exactly as if they had been added one at a time.
 */
export interface CartLine {
  key: number
  item: MenuItem
  options: MenuOption[]
  quantity: number
  unitPriceCents: number
}

export interface Cart {
  lines: CartLine[]
  totalCents: number
  drinkCount: number
  add: (item: MenuItem, options: MenuOption[], quantity?: number) => void
  setQuantity: (key: number, quantity: number) => void
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

  const add = useCallback((item: MenuItem, options: MenuOption[], quantity = 1) => {
    const key = nextKey.current++

    setLines((current) => {
      // The same drink with the same options is the same line. Two identical
      // rows next to a quantity control reads as a bug, and a customer who taps
      // a drink twice means two of it.
      const existing = current.findIndex((line) => signature(line) === signatureOf(item, options))

      if (existing !== -1) {
        return current.map((line, index) =>
          index === existing ? { ...line, quantity: line.quantity + quantity } : line,
        )
      }

      return [
        ...current,
        {
          key,
          item,
          options,
          quantity,
          unitPriceCents: item.price_cents + options.reduce((sum, o) => sum + o.price_cents, 0),
        },
      ]
    })
  }, [])

  // Dropping to zero removes the line rather than leaving a row that is in the
  // cart but not in the order.
  const setQuantity = useCallback((key: number, quantity: number) => {
    setLines((current) =>
      quantity < 1
        ? current.filter((line) => line.key !== key)
        : current.map((line) => (line.key === key ? { ...line, quantity } : line)),
    )
  }, [])

  const remove = useCallback((key: number) => {
    setLines((current) => current.filter((line) => line.key !== key))
  }, [])

  const clear = useCallback(() => setLines([]), [])

  const totalCents = useMemo(
    () => lines.reduce((sum, line) => sum + line.unitPriceCents * line.quantity, 0),
    [lines],
  )

  const drinkCount = useMemo(
    () => lines.reduce((sum, line) => sum + line.quantity, 0),
    [lines],
  )

  return { lines, totalCents, drinkCount, add, setQuantity, remove, clear }
}

/**
 * The shape `POST /orders` wants, with quantities expanded.
 *
 * Three of a drink is three entries, not one with a count: the API has no
 * quantity and must not grow one, because `OrderItem` is the unit the scheduler
 * dispatches (§2). A quantity on the wire would have to be expanded somewhere,
 * and doing it here keeps the server's contract the same as it was.
 */
export function toOrderItems(lines: CartLine[]) {
  return lines.flatMap((line) =>
    Array.from({ length: line.quantity }, () => ({
      menu_item_id: line.item.id,
      option_ids: line.options.map((option) => option.id),
    })),
  )
}

function signature(line: CartLine): string {
  return signatureOf(line.item, line.options)
}

function signatureOf(item: MenuItem, options: MenuOption[]): string {
  const ids = options.map((option) => option.id).sort((a, b) => a - b)

  return `${item.id}:${ids.join(',')}`
}

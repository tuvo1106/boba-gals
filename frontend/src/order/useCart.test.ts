import { act, renderHook } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { toOrderItems, useCart } from './useCart'
import type { MenuItem, MenuOption } from '../api/types'

function menuItem(overrides: Partial<MenuItem> = {}): MenuItem {
  return {
    id: 1, name: 'Classic Milk Tea', category: 'milk_tea',
    price_cents: 550, base_prep_seconds: 45, option_groups: [], ...overrides,
  }
}

function option(overrides: Partial<MenuOption> = {}): MenuOption {
  return { id: 9, name: 'Boba pearls', price_cents: 75, prep_seconds_delta: 15, ...overrides }
}

describe('useCart', () => {
  it('totals the drink plus its options', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), [ option() ]))

    expect(result.current.totalCents).toBe(625)
  })

  it('multiplies the line total by the quantity', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), [ option() ], 3))

    expect(result.current.totalCents).toBe(1875)
    expect(result.current.drinkCount).toBe(3)
  })

  it('is empty and free to start with', () => {
    const { result } = renderHook(() => useCart())

    expect(result.current.lines).toEqual([])
    expect(result.current.totalCents).toBe(0)
  })

  // Two identical rows next to a quantity control reads as a bug, and a
  // customer who taps the same drink twice means two of it.
  it('merges a drink added twice with the same options', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), []))
    act(() => result.current.add(menuItem(), []))

    expect(result.current.lines).toHaveLength(1)
    expect(result.current.lines[0].quantity).toBe(2)
  })

  it('keeps the same drink with different options apart', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), [ option({ id: 3 }) ]))
    act(() => result.current.add(menuItem(), [ option({ id: 4 }) ]))

    expect(result.current.lines).toHaveLength(2)
  })

  // The same options chosen in a different order are the same drink.
  it('does not care what order the options were chosen in', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), [ option({ id: 3 }), option({ id: 9 }) ]))
    act(() => result.current.add(menuItem(), [ option({ id: 9 }), option({ id: 3 }) ]))

    expect(result.current.lines).toHaveLength(1)
    expect(result.current.lines[0].quantity).toBe(2)
  })

  it('changes the quantity of one line', () => {
    const { result } = renderHook(() => useCart())
    act(() => result.current.add(menuItem(), []))

    act(() => result.current.setQuantity(result.current.lines[0].key, 4))

    expect(result.current.drinkCount).toBe(4)
  })

  // A row that is in the cart but not in the order would be worse than gone.
  it('removes a line stepped below one', () => {
    const { result } = renderHook(() => useCart())
    act(() => result.current.add(menuItem(), []))

    act(() => result.current.setQuantity(result.current.lines[0].key, 0))

    expect(result.current.lines).toEqual([])
  })

  it('removes only the line asked for', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), []))
    act(() => result.current.add(menuItem({ id: 2, name: 'Taro Slush' }), []))
    act(() => result.current.remove(result.current.lines[0].key))

    expect(result.current.lines.map((line) => line.item.name)).toEqual([ 'Taro Slush' ])
  })

  it('empties on clear', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), []))
    act(() => result.current.clear())

    expect(result.current.lines).toEqual([])
    expect(result.current.totalCents).toBe(0)
  })
})

describe('toOrderItems', () => {
  it('sends the menu item and the chosen option ids, and nothing else', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), [ option({ id: 3 }), option({ id: 7 }) ]))

    expect(toOrderItems(result.current.lines)).toEqual([
      { menu_item_id: 1, option_ids: [ 3, 7 ] },
    ])
  })

  // The API has no quantity and must not grow one: `OrderItem` is the unit the
  // scheduler dispatches (§2), so three of a drink is three entries.
  it('expands a quantity into one entry per drink', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), [ option({ id: 3 }) ], 3))

    const items = toOrderItems(result.current.lines)
    expect(items).toHaveLength(3)
    expect(items.every((i) => i.menu_item_id === 1)).toBe(true)
    expect(JSON.stringify(items)).not.toContain('quantity')
  })

  // Prices and prep times are the server's to compute from its own menu (§4.1).
  // Sending our copy would invite someone to send a different one.
  it('never sends a price', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), [ option() ]))

    expect(JSON.stringify(toOrderItems(result.current.lines))).not.toContain('price')
  })
})

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

  it('is empty and free to start with', () => {
    const { result } = renderHook(() => useCart())

    expect(result.current.lines).toEqual([])
    expect(result.current.totalCents).toBe(0)
  })

  // Two identical drinks are two lines, not a quantity of two — §2 makes the
  // drink the unit of work, and removing one must not remove both.
  it('keeps identical drinks as separate lines', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), []))
    act(() => result.current.add(menuItem(), []))

    expect(result.current.lines).toHaveLength(2)
    expect(result.current.lines[0].key).not.toBe(result.current.lines[1].key)
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

  // Prices and prep times are the server's to compute from its own menu (§4.1).
  // Sending our copy would invite someone to send a different one.
  it('never sends a price', () => {
    const { result } = renderHook(() => useCart())

    act(() => result.current.add(menuItem(), [ option() ]))

    expect(JSON.stringify(toOrderItems(result.current.lines))).not.toContain('price')
  })
})

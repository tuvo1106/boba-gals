import { useEffect, useState } from 'react'
import { apiGet, apiPost } from '../api/client'
import { formatPrice } from './money'
import { tapTarget, type OrderingMode } from './mode'
import { toOrderItems, useCart } from './useCart'
import { DrinkCustomizer } from './DrinkCustomizer'
import { CheckoutForm, type CheckoutDetails } from './CheckoutForm'
import { OrderStatusScreen } from './OrderStatusScreen'
import { blocksOrdering, useHealth } from './useHealth'
import type { HealthState } from './useHealth'
import type { Menu, MenuItem, MenuOption, PlacedOrder } from '../api/types'

/**
 * The ordering app (§9.3). One codebase for the kiosk and the web; the mode is
 * a runtime flag rather than a fork, and what it changes lives in `mode.ts`.
 *
 * Three steps, because there are only three: pick drinks, say who you are, and
 * watch it being made. Payment is at the counter (§9.3, locked), so there is no
 * fourth.
 */
export function OrderingApp({ mode }: { mode: OrderingMode }) {
  const cart = useCart()
  // Kiosk only (§9.3). The web flow is a phone, which shows its own
  // connectivity and has no attract screen to fall back to.
  const health = useHealth(mode === 'kiosk')
  const [menu, setMenu] = useState<Menu | null>(null)
  const [menuError, setMenuError] = useState<string | null>(null)
  const [customizing, setCustomizing] = useState<MenuItem | null>(null)
  const [checkingOut, setCheckingOut] = useState(false)
  const [placed, setPlaced] = useState<PlacedOrder | null>(null)
  const [placing, setPlacing] = useState(false)
  const [placeError, setPlaceError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false

    apiGet<Menu>('/menu')
      .then((fetched) => !cancelled && setMenu(fetched))
      .catch(() => !cancelled && setMenuError('The menu could not be loaded.'))

    return () => {
      cancelled = true
    }
  }, [])

  async function place(details: CheckoutDetails) {
    setPlacing(true)
    setPlaceError(null)

    try {
      const order = await apiPost<PlacedOrder>('/orders', {
        order: { source: mode, ...details, items: toOrderItems(cart.lines) },
      })

      setPlaced(order)
      cart.clear()
    } catch (e) {
      // §9.3: no optimistic accept. A customer holding a receipt for a drink
      // the kitchen never saw is strictly worse than a clear refusal, so the
      // cart stays exactly as it was and they can try again.
      setPlaceError(e instanceof Error ? e.message : 'We could not place that order.')
    } finally {
      setPlacing(false)
    }
  }

  function startOver() {
    setPlaced(null)
    setCheckingOut(false)
  }

  // Above everything, including the confirmation screen — a kiosk that cannot
  // reach the shop cannot be trusted to be showing a live order either.
  //
  // Rendered as an overlay rather than by clearing state, because §9.3 is
  // explicit that the cart survives: "The cart is preserved in memory so a
  // brief blip doesn't lose an in-progress order."
  if (blocksOrdering(health)) return <Paused mode={mode} state={health} />

  if (placed) {
    return (
      <OrderStatusScreen
        pickupCode={placed.pickup_code}
        seed={placed}
        mode={mode}
        onStartOver={startOver}
      />
    )
  }

  if (checkingOut) {
    return (
      <CheckoutForm
        lines={cart.lines}
        totalCents={cart.totalCents}
        mode={mode}
        busy={placing}
        error={placeError}
        onPlace={place}
        onBack={() => setCheckingOut(false)}
        onQuantityChange={cart.setQuantity}
      />
    )
  }

  return (
    <main className="min-h-screen bg-neutral-950 pb-28 text-neutral-100">
      <header className="border-b border-neutral-800 px-6 py-5">
        <h1 className="text-3xl font-semibold tracking-tight">Boba Gals</h1>
      </header>

      {menuError && (
        <p role="alert" className="bg-rose-950 px-6 py-3 font-mono text-sm text-rose-300">
          {menuError}
        </p>
      )}

      <div className="mx-auto max-w-3xl px-6 py-6">
        {menu === null && !menuError && <p className="text-neutral-500">Loading the menu…</p>}

        {menu && (
          <div className="flex flex-col gap-8">
            {categories(menu).map(([ category, items ]) => (
              <section key={category} aria-label={category}>
                <h2 className="mb-3 font-mono text-xs tracking-widest text-neutral-500 uppercase">
                  {category.replace(/_/g, ' ')}
                </h2>

                <ul className="flex flex-col gap-2">
                  {items.map((item) => (
                    <li key={item.id}>
                      <button
                        onClick={() => setCustomizing(item)}
                        className={`flex w-full items-center gap-4 rounded-lg border border-neutral-800 px-5 text-left hover:border-amber-500 ${tapTarget(mode)}`}
                      >
                        <span className="font-semibold">{item.name}</span>
                        <span className="ml-auto font-mono tabular-nums text-neutral-400">
                          {formatPrice(item.price_cents)}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              </section>
            ))}
          </div>
        )}
      </div>

      {customizing && (
        <DrinkCustomizer
          item={customizing}
          mode={mode}
          onCancel={() => setCustomizing(null)}
          onAdd={(options: MenuOption[], quantity: number) => {
            cart.add(customizing, options, quantity)
            setCustomizing(null)
          }}
        />
      )}

      {/* Pinned rather than at the end of the menu: on a kiosk the menu is
          longer than the screen, and a cart the customer has to scroll to find
          is a cart they abandon at the counter. */}
      {cart.lines.length > 0 && (
        <footer className="fixed inset-x-0 bottom-0 border-t border-neutral-800 bg-neutral-900 px-6 py-4">
          <div className="mx-auto flex max-w-3xl items-center gap-4">
            {/* flex-1 so the summary takes the slack and the button is pinned
                to the right edge of the bar. Without it the button sits
                wherever the drink list happens to end — halfway across on a
                one-line cart, which reads as a stray control rather than the
                bar's action. `min-w-0` keeps the truncate working inside it. */}
            <div className="min-w-0 flex-1">
              {/* Counts drinks, not lines. A line of three is three cups the
                  kitchen has to make, and three rows on the KDS (§2). */}
              <p className="font-mono text-xs tracking-widest text-neutral-500 uppercase">
                {cart.drinkCount} {cart.drinkCount === 1 ? 'drink' : 'drinks'}
              </p>
              <p className="truncate text-sm text-neutral-400">
                {cart.lines
                  .map((line) => (line.quantity > 1 ? `${line.quantity} × ` : '') + line.item.name)
                  .join(', ')}
              </p>
            </div>

            <button
              onClick={() => setCheckingOut(true)}
              className={`rounded-lg bg-amber-600 px-8 font-semibold text-neutral-950 hover:bg-amber-500 ${tapTarget(mode)}`}
            >
              Review · {formatPrice(cart.totalCents)}
            </button>
          </div>
        </footer>
      )}
    </main>
  )
}

/**
 * §9.3, locked in §3. The wording is the design's, verbatim.
 *
 * No local queue and no optimistic accept, and this screen is why: "a queued
 * order that fails to sync produces a customer holding a receipt for a drink
 * the kitchen never saw — strictly worse than a clear refusal."
 *
 * Sized for someone standing at a kiosk reading it from a step away, and
 * deliberately says what to do next rather than only what is wrong.
 */
function Paused({ mode, state }: { mode: OrderingMode; state: HealthState }) {
  return (
    <main
      role="alert"
      className="grid min-h-screen place-items-center bg-neutral-950 px-8 text-neutral-100"
    >
      <div className={`text-center ${mode === 'kiosk' ? 'max-w-2xl' : 'max-w-md'}`}>
        <p className="font-mono text-sm tracking-widest text-amber-500 uppercase">Boba Gals</p>
        <h1 className="mt-4 text-5xl font-semibold tracking-tight">Ordering is paused</h1>
        <p className="mt-6 text-2xl text-neutral-400">
          {state === 'unreachable'
            ? 'The kiosk can\u2019t reach the store system.'
            : 'The shop isn\u2019t taking orders right now.'}
        </p>
        <p className="mt-2 text-2xl text-neutral-300">Please order at the counter.</p>
      </div>
    </main>
  )
}

/** Groups the menu by `category`, keeping the server's ordering within each. */
function categories(menu: Menu): [ string, MenuItem[] ][] {
  const grouped = new Map<string, MenuItem[]>()

  for (const item of menu.items) {
    const bucket = grouped.get(item.category)
    if (bucket) bucket.push(item)
    else grouped.set(item.category, [ item ])
  }

  return [ ...grouped.entries() ]
}

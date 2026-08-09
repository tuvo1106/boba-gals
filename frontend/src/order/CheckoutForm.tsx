import { useState } from 'react'
import { formatPrice } from './money'
import { tapTarget, type OrderingMode } from './mode'
import type { CartLine } from './useCart'

export interface CheckoutDetails {
  customer_first_name: string
  customer_phone?: string
}

/**
 * Name, optional phone, and pay at the counter (§9.3).
 *
 * **Payment is locked for v1**: record `total_cents`, settle at the register.
 * There is no card field here and there must not be one — the terminal and
 * Stripe integrations sit behind the `PaymentProvider` port on the server and
 * are integration work, not design work.
 *
 * The phone field is web-only. A kiosk order has nobody to text (§9.7), and
 * `Order` rejects a `customer_phone` on a kiosk order outright.
 */
export function CheckoutForm({
  lines,
  totalCents,
  mode,
  busy,
  error,
  onPlace,
  onBack,
}: {
  lines: CartLine[]
  totalCents: number
  mode: OrderingMode
  busy: boolean
  error: string | null
  onPlace: (details: CheckoutDetails) => void
  onBack: () => void
}) {
  const [firstName, setFirstName] = useState('')
  const [phone, setPhone] = useState('')

  function submit(event: React.FormEvent) {
    event.preventDefault()

    onPlace({
      customer_first_name: firstName.trim(),
      // Omitted rather than sent empty: `""` would be a value, and `Order`
      // rejects a `customer_phone` on a kiosk order outright.
      //
      // There is no `mode === 'web'` check here on purpose. The field is only
      // rendered on the web, so this is always empty at a kiosk — a second
      // check would be a branch no test could reach, which is how a guard ends
      // up believed rather than known.
      ...(phone.trim() ? { customer_phone: phone.trim() } : {}),
    })
  }

  return (
    <main className="min-h-screen bg-neutral-950 px-6 py-8 text-neutral-100">
      <div className="mx-auto flex max-w-xl flex-col gap-8">
        <h1 className="text-3xl font-semibold tracking-tight">Your order</h1>

        <ul className="flex flex-col divide-y divide-neutral-800">
          {lines.map((line) => (
            <li key={line.key} className="flex items-baseline gap-4 py-3">
              <span>
                {line.item.name}
                {line.options.length > 0 && (
                  <span className="ml-2 text-sm text-neutral-500">
                    {line.options.map((o) => o.name).join(', ')}
                  </span>
                )}
              </span>
              <span className="ml-auto font-mono tabular-nums text-neutral-400">
                {formatPrice(line.priceCents)}
              </span>
            </li>
          ))}
          <li className="flex items-baseline gap-4 py-3 font-semibold">
            <span>Total</span>
            <span className="ml-auto font-mono tabular-nums">{formatPrice(totalCents)}</span>
          </li>
        </ul>

        <form onSubmit={submit} className="flex flex-col gap-5">
          <label className="flex flex-col gap-1.5 font-mono text-xs tracking-widest text-neutral-500 uppercase">
            first name
            <input
              value={firstName}
              onChange={(e) => setFirstName(e.target.value)}
              required
              aria-label="first name"
              autoComplete="given-name"
              className={`rounded-lg border border-neutral-700 bg-transparent px-4 text-lg normal-case text-neutral-100 focus:border-amber-500 focus:outline-none ${tapTarget(mode)}`}
            />
            {/* §3, locked: the board shows first name and pickup code only. */}
            <span className="text-[10px] normal-case tracking-normal text-neutral-600">
              Shown on the pickup board with your code.
            </span>
          </label>

          {mode === 'web' && (
            <label className="flex flex-col gap-1.5 font-mono text-xs tracking-widest text-neutral-500 uppercase">
              phone (optional)
              <input
                type="tel"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                aria-label="phone"
                autoComplete="tel"
                className={`rounded-lg border border-neutral-700 bg-transparent px-4 text-lg normal-case text-neutral-100 focus:border-amber-500 focus:outline-none ${tapTarget(mode)}`}
              />
              <span className="text-[10px] normal-case tracking-normal text-neutral-600">
                One text when it is ready. Never shown on the board.
              </span>
            </label>
          )}

          <p className="rounded-lg border border-neutral-800 bg-neutral-900 px-4 py-3 text-sm text-neutral-400">
            Pay at the counter when you collect.
          </p>

          {error && (
            <p role="alert" className="font-mono text-sm text-rose-400">
              {error}
            </p>
          )}

          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={onBack}
              className={`rounded-lg border border-neutral-700 px-6 text-neutral-300 hover:border-neutral-500 ${tapTarget(mode)}`}
            >
              Back
            </button>
            <button
              type="submit"
              disabled={busy}
              className={`ml-auto flex-1 rounded-lg bg-amber-600 px-8 text-lg font-semibold text-neutral-950 disabled:opacity-40 hover:bg-amber-500 ${tapTarget(mode)}`}
            >
              {busy ? 'Placing…' : 'Place order'}
            </button>
          </div>
        </form>
      </div>
    </main>
  )
}

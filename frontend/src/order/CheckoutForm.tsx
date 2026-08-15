import { useState } from 'react'
import { formatPrice } from './money'
import { tapTarget, type OrderingMode } from './mode'
import { Stepper } from './Stepper'
import type { CartLine } from './useCart'

export interface CheckoutDetails {
  customer_first_name: string
  customer_phone?: string
}

/**
 * Whether a number could receive the ready text (§9.7).
 *
 * Mirrors `Order::PHONE_FORMAT` deliberately — 10 to 15 digits, E.164's ceiling
 * at the top and the shortest reachable mobile at the bottom, with the
 * formatting people actually type stripped rather than rejected. The server
 * validates independently; this exists so the customer hears about a typo while
 * they can still fix it, not after the order is placed.
 */
function isReachable(phone: string): boolean {
  return /^\+?\d{10,15}$/.test(phone.trim().replace(/[\s().-]/g, ''))
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
  onQuantityChange,
}: {
  lines: CartLine[]
  totalCents: number
  mode: OrderingMode
  busy: boolean
  error: string | null
  onPlace: (details: CheckoutDetails) => void
  onBack: () => void
  onQuantityChange: (key: number, quantity: number) => void
}) {
  const [firstName, setFirstName] = useState('')
  const [phone, setPhone] = useState('')
  const [phoneError, setPhoneError] = useState<string | null>(null)

  const empty = lines.length === 0

  function submit(event: React.FormEvent) {
    event.preventDefault()

    // The stepper on this screen goes to zero (that is deliberate — this is the
    // last chance to take something off the order), so the cart can empty while
    // the customer is standing on it. Nothing sent them back, so "Place order"
    // stayed live over an empty list and posted an order with no items. The
    // server refuses it, but the customer's own screen already knew.
    if (empty) return

    // Checked here as well as on the server, because the server's answer costs
    // a round trip and arrives as a generic failure — and the number is the one
    // field where a typo is silent: the order is placed, the drinks are made,
    // and the text goes nowhere.
    if (phone.trim() && !isReachable(phone)) {
      setPhoneError('That does not look like a number we can text. Leave it blank to skip the text.')
      return
    }

    setPhoneError(null)
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
            <li key={line.key} className="flex items-center gap-4 py-3">
              <span className="min-w-0">
                {line.item.name}
                {line.options.length > 0 && (
                  <span className="ml-2 text-sm text-neutral-500">
                    {line.options.map((o) => o.name).join(', ')}
                  </span>
                )}
              </span>

              {/* `min={0}` — here, unlike in the customizer, stepping below one
                  removes the line. This is the last screen before the order is
                  placed, so it has to be possible to take something off it. */}
              <Stepper
                quantity={line.quantity}
                mode={mode}
                min={0}
                label={`Quantity of ${line.item.name}`}
                onChange={(quantity) => onQuantityChange(line.key, quantity)}
                className="ml-auto shrink-0"
              />

              <span className="w-20 shrink-0 text-right font-mono tabular-nums text-neutral-400">
                {formatPrice(line.unitPriceCents * line.quantity)}
              </span>
            </li>
          ))}
          {empty && (
            <li className="py-3 text-neutral-500">
              Your cart is empty — go back and add a drink.
            </li>
          )}
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
                onChange={(e) => {
                  setPhone(e.target.value)
                  // Clears as soon as they start fixing it. Leaving the error up
                  // while the field is being corrected reads as "still wrong".
                  if (phoneError) setPhoneError(null)
                }}
                aria-label="phone"
                autoComplete="tel"
                inputMode="tel"
                aria-invalid={phoneError ? true : undefined}
                aria-describedby={phoneError ? 'phone-error' : undefined}
                className={`rounded-lg border bg-transparent px-4 text-lg normal-case text-neutral-100 focus:outline-none ${phoneError ? 'border-rose-500' : 'border-neutral-700 focus:border-amber-500'} ${tapTarget(mode)}`}
              />
              {phoneError ? (
                <span id="phone-error" role="alert" className="text-[10px] normal-case tracking-normal text-rose-400">
                  {phoneError}
                </span>
              ) : (
                <span className="text-[10px] normal-case tracking-normal text-neutral-600">
                  One text when it is ready. Never shown on the board.
                </span>
              )}
            </label>
          )}

          {/* No timing claimed. §9.3 says "settle at the register" and does not
              say when — "when you collect" was invented here, and it is the
              unusual reading: it would mean queueing at the register anyway,
              after using the kiosk to avoid exactly that. When payment is
              actually taken is a §16 question, not this component's to answer. */}
          <p className="rounded-lg border border-neutral-800 bg-neutral-900 px-4 py-3 text-sm text-neutral-400">
            Pay at the counter.
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
              disabled={busy || empty}
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

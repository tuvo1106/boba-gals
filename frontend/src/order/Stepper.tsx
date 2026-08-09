import { tapTarget, type OrderingMode } from './mode'

/**
 * A quantity control (§9.3).
 *
 * Buttons rather than a number input: a kiosk has no keyboard, and a phone
 * keypad covering half the screen to change a 2 into a 3 is worse than two
 * taps. `−` at 1 is disabled here rather than removing the line, because this
 * one is used while *building* a drink — the cart's own stepper does remove.
 */
export function Stepper({
  quantity,
  mode,
  label,
  onChange,
  min = 1,
  className = '',
}: {
  quantity: number
  mode: OrderingMode
  label: string
  onChange: (quantity: number) => void
  min?: number
  className?: string
}) {
  const size = mode === 'kiosk' ? 'w-16' : 'w-11'

  return (
    <div role="group" aria-label={label} className={`flex items-center gap-1 ${className}`}>
      <button
        type="button"
        aria-label={`One fewer ${label}`}
        disabled={quantity <= min}
        onClick={() => onChange(quantity - 1)}
        className={`${size} ${tapTarget(mode)} rounded-lg border border-neutral-700 text-xl text-neutral-300 disabled:opacity-30 hover:border-neutral-500`}
      >
        −
      </button>

      {/* Tabular figures so the row does not jog sideways going 9 → 10. */}
      <output aria-label={label} className="w-8 text-center font-mono text-lg tabular-nums">
        {quantity}
      </output>

      <button
        type="button"
        aria-label={`One more ${label}`}
        onClick={() => onChange(quantity + 1)}
        className={`${size} ${tapTarget(mode)} rounded-lg border border-neutral-700 text-xl text-neutral-300 hover:border-neutral-500`}
      >
        +
      </button>
    </div>
  )
}

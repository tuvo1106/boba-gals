import { useState } from 'react'
import { formatPrice, formatPriceDelta } from './money'
import type { MenuItem, MenuOption, OptionGroup } from '../api/types'
import type { OrderingMode } from './mode'
import { tapTarget } from './mode'

/**
 * Choosing the options on one drink (§9.3).
 *
 * The control is decided by the group, not hardcoded: a radio group when at
 * most one may be chosen, a checkbox set otherwise (ADR-0003). That is the
 * whole reason `min_select`/`max_select` travel to the client, and it means a
 * new option group added to the menu renders correctly without a code change.
 *
 * Selection counts are validated here *and* on the server (`CreateOrder`). This
 * copy exists so the customer is told before they tap, not after.
 */
export function DrinkCustomizer({
  item,
  mode,
  onAdd,
  onCancel,
}: {
  item: MenuItem
  mode: OrderingMode
  onAdd: (options: MenuOption[]) => void
  onCancel: () => void
}) {
  const [chosen, setChosen] = useState<Record<number, number[]>>({})

  const selectedIn = (group: OptionGroup) => chosen[group.id] ?? []
  const unmet = item.option_groups.filter((group) => selectedIn(group).length < group.min_select)

  const options = item.option_groups.flatMap((group) =>
    group.options.filter((option) => selectedIn(group).includes(option.id)),
  )
  const priceCents = item.price_cents + options.reduce((sum, o) => sum + o.price_cents, 0)

  function toggle(group: OptionGroup, optionId: number) {
    setChosen((current) => {
      const selected = current[group.id] ?? []

      if (group.max_select === 1) return { ...current, [group.id]: [ optionId ] }
      if (selected.includes(optionId)) {
        return { ...current, [group.id]: selected.filter((id) => id !== optionId) }
      }
      // Silently ignoring the tap past the limit is worse than it sounds: the
      // customer taps, nothing happens, and there is nothing on screen saying
      // why. The count in the group heading is what explains it.
      if (selected.length >= group.max_select) return current

      return { ...current, [group.id]: [ ...selected, optionId ] }
    })
  }

  return (
    // Opaque rather than a 95% scrim. At 95% the pinned cart bar showed through
    // the footer, putting a ghosted "Review · $6.25" inches from "Add to
    // order" — two totals and two primary-looking buttons on one screen.
    <div
      role="dialog"
      aria-label={`Customize ${item.name}`}
      className="fixed inset-0 z-10 flex flex-col bg-neutral-950 text-neutral-100"
    >
      <header className="flex items-baseline gap-4 border-b border-neutral-800 px-6 py-4">
        <h2 className="text-3xl font-semibold tracking-tight">{item.name}</h2>
        <span className="font-mono text-xl tabular-nums text-neutral-400">
          {formatPrice(priceCents)}
        </span>
      </header>

      <div className="flex-1 overflow-y-auto px-6 py-5">
        <div className="mx-auto flex max-w-2xl flex-col gap-7">
          {item.option_groups.map((group) => (
            <fieldset key={group.id}>
              <legend className="mb-2 flex w-full items-baseline gap-3">
                <span className="text-lg font-semibold">{group.name}</span>
                <span className="font-mono text-xs tracking-widest text-neutral-500 uppercase">
                  {describe(group)}
                </span>
              </legend>

              <div className="flex flex-wrap gap-2">
                {group.options.map((option) => {
                  const selected = selectedIn(group).includes(option.id)

                  return (
                    <label
                      key={option.id}
                      className={`flex cursor-pointer items-center gap-2 rounded-lg border-2 px-4 ${tapTarget(mode)} ${
                        selected
                          ? 'border-amber-500 bg-amber-950/40 text-amber-200'
                          : 'border-neutral-700 text-neutral-300 hover:border-neutral-500'
                      }`}
                    >
                      <input
                        type={group.max_select === 1 ? 'radio' : 'checkbox'}
                        name={`group-${group.id}`}
                        checked={selected}
                        onChange={() => toggle(group, option.id)}
                        className="sr-only"
                      />
                      <span>{option.name}</span>
                      {option.price_cents > 0 && (
                        <span className="font-mono text-sm text-neutral-500">
                          {formatPriceDelta(option.price_cents)}
                        </span>
                      )}
                    </label>
                  )
                })}
              </div>
            </fieldset>
          ))}
        </div>
      </div>

      <footer className="flex items-center gap-4 border-t border-neutral-800 px-6 py-4">
        <button
          onClick={onCancel}
          className={`rounded-lg border border-neutral-700 px-6 text-neutral-300 hover:border-neutral-500 ${tapTarget(mode)}`}
        >
          Cancel
        </button>

        {unmet.length > 0 && (
          <p role="status" className="font-mono text-sm text-neutral-500">
            Choose {unmet[0].name.toLowerCase()}
          </p>
        )}

        <button
          onClick={() => onAdd(options)}
          disabled={unmet.length > 0}
          className={`ml-auto rounded-lg bg-amber-600 px-8 text-lg font-semibold text-neutral-950 disabled:opacity-40 hover:bg-amber-500 ${tapTarget(mode)}`}
        >
          Add to order
        </button>
      </footer>
    </div>
  )
}

function describe(group: OptionGroup): string {
  if (group.min_select === 1 && group.max_select === 1) return 'pick one'
  if (group.min_select === 0 && group.max_select === 1) return 'optional'
  if (group.min_select === 0) return `up to ${group.max_select}`

  return `${group.min_select}–${group.max_select}`
}

import type { SimulationMetrics } from '../api/types'

/** §10.4's three classes, in the order the design lists them. */
const SIZE_CLASSES = [
  { key: '1-2', label: '1–2 drinks', note: 'the headline — this is the line that must stay flat' },
  { key: '3-6', label: '3–6 drinks', note: 'the middle, where neither claim is being tested' },
  { key: '7+', label: '7+ drinks', note: 'catering — expected to be higher, and to rise while 1–2 does not' },
] as const

function secs(value: number): string {
  return `${Math.round(value)}s`
}

/**
 * §10.4's supporting table, rendered: wait percentiles by size class, and the
 * accuracy of what the customer was told.
 *
 * **p50 / p90 / p99, never the mean** — §10.4 opens with that rule, because "the
 * mean hides exactly the failures fair queuing exists to prevent". All three
 * columns for all three classes: `Metrics#by_size_class` has computed nine
 * numbers since it was written, and the panel above this one renders two of
 * them. A scheduler that starves the middle class was, until now, not visible
 * on this screen at all.
 *
 * The one deliberate mean is `bias`, and it is separated out below for that
 * reason.
 */
export function MetricGrid({ metrics }: { metrics: SimulationMetrics }) {
  return (
    <section className="mt-8 border-t border-neutral-800 pt-4">
      <h2 className="mb-3 font-mono text-xs tracking-widest text-neutral-500 uppercase">
        How long people waited (§10.4)
      </h2>

      <div className="overflow-x-auto">
        <table className="w-full min-w-125 border-collapse font-mono text-xs">
          <thead>
            <tr className="text-neutral-600">
              <th scope="col" className="py-1 pr-4 text-left font-normal">order size</th>
              <th scope="col" className="py-1 pr-4 text-right font-normal">orders</th>
              <th scope="col" className="py-1 pr-4 text-right font-normal" title="Half of customers waited less than this">
                typical
              </th>
              <th scope="col" className="py-1 pr-4 text-right font-normal" title="9 in 10 customers waited less than this">
                9 in 10
              </th>
              <th scope="col" className="py-1 pr-4 text-right font-normal" title="99 in 100 — the worst day anyone had">
                99 in 100
              </th>
            </tr>
          </thead>
          <tbody>
            {SIZE_CLASSES.map(({ key, label, note }) => {
              const row = metrics.by_size_class[key]
              if (!row) return null

              return (
                <tr key={key} className="border-t border-neutral-900">
                  <th scope="row" className="py-1.5 pr-4 text-left font-normal text-neutral-300" title={note}>
                    {label}
                  </th>
                  <td className="py-1.5 pr-4 text-right tabular-nums text-neutral-500">
                    {row.orders}
                    {/* A p90 over five orders is the maximum, not a percentile —
                        the same caveat the ablation chart carries, and the
                        reason the count sits next to the figures rather than
                        being left for someone to wonder about. */}
                    {!row.p90_meaningful && (
                      <span
                        className="ml-1 text-amber-600"
                        title="Too few orders for these to be percentiles — the p90 and p99 here are close to the slowest one. Raise demand or lengthen the run."
                      >
                        ⚠
                      </span>
                    )}
                  </td>
                  <td className="py-1.5 pr-4 text-right tabular-nums text-neutral-300">{secs(row.p50)}</td>
                  <td className="py-1.5 pr-4 text-right tabular-nums text-amber-500">{secs(row.p90)}</td>
                  <td className="py-1.5 pr-4 text-right tabular-nums text-neutral-400">{secs(row.p99)}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      <EtaAccuracy accuracy={metrics.eta_accuracy} />
    </section>
  )
}

/**
 * §10.4's ETA row, and §7.3's argument: "This is the difference between a board
 * customers trust and one they learn to ignore."
 *
 * Bias is a **signed mean** and the only mean on this screen. That is not an
 * oversight in §10.4 — absolute error asks "how far off is a typical quote",
 * bias asks "is the shop systematically late", and a median signed error cannot
 * answer the second. A shop that beats its quote by a second on half its orders
 * and is four minutes late on the rest has a median near zero.
 */
function EtaAccuracy({ accuracy }: { accuracy: SimulationMetrics['eta_accuracy'] }) {
  const { p50_abs, p90_abs, bias, orders, capped, measurable } = accuracy

  // Late is the direction that costs trust: a customer only notices the half
  // where the drink is not ready (§7.3).
  const late = bias > 0
  const severity = Math.abs(bias) > 120 ? 'text-amber-500' : 'text-emerald-500'

  return (
    <div className="mt-6">
      <h3 className="mb-2 font-mono text-xs tracking-widest text-neutral-500 uppercase">
        Was the quote any good? (§10.4)
      </h3>

      {orders === 0 ? (
        <p className="font-mono text-xs text-neutral-600">No completed orders to score.</p>
      ) : (
        <dl className="grid grid-cols-1 gap-x-8 gap-y-2 font-mono text-xs sm:grid-cols-3">
          <Figure
            label="typical miss" value={secs(p50_abs)}
            hint={`Half of quotes were closer than this. Over ${orders} orders${measurable ? '' : ' — too few to be a percentile'}.`}
            state={measurable ? undefined : 'warn'}
          />
          <Figure
            label="worst 10%" value={secs(p90_abs)}
            hint="One order in ten missed its quote by at least this much."
          />
          <Figure
            label="bias"
            value={`${bias > 0 ? '+' : ''}${secs(bias)}`}
            tone={severity}
            hint={
              late
                ? `On average the shop was ready ${secs(bias)} later than it said. Bias is the figure §7.3 says destroys trust — a customer only notices the half where the drink is not ready.`
                : `On average the shop was ready ${secs(Math.abs(bias))} earlier than it said. Over-quoting is the safer direction, but a large negative bias means customers are told to wait longer than they need to.`
            }
          />
        </dl>
      )}

      {capped > 0 && (
        <p className="mt-2 font-mono text-xs text-neutral-500">
          {capped} order{capped === 1 ? '' : 's'} queued past the hour the projection looks ahead, so
          {capped === 1 ? ' its quote is' : ' their quotes are'} a floor rather than an estimate and
          {capped === 1 ? ' it is' : ' they are'} left out of the figures above. A run with many of these is a
          shop well past saturation.
        </p>
      )}
    </div>
  )
}

function Figure({
  label, value, hint, tone, state,
}: {
  label: string
  value: string
  hint: string
  tone?: string
  state?: 'warn'
}) {
  return (
    <div className="flex flex-col gap-0.5" title={hint}>
      <dt className="text-neutral-600">
        {label}
        {state === 'warn' && <span className="ml-1 text-amber-600">⚠</span>}
      </dt>
      <dd className={`text-base tabular-nums ${tone ?? 'text-neutral-200'}`}>{value}</dd>
    </div>
  )
}

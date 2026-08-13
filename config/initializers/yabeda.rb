# Business metrics (§15), beyond yabeda-rails' framework defaults. §10.4
# named these; production watches the same definitions the simulator already
# validated, or the dashboard number and the prod number can't be compared.
#
# Two different mechanisms, on purpose:
#
# **Histograms are observed inline**, from `FinishDrink` — the one call site
# where an order transitions to `ready` (§5.1's forward lifecycle only reaches
# it there; see the comment at that call site for why it's exactly-once per
# transition). That code always runs inside a web request, so the observation
# always lands in a `web` pod's own in-process registry, which is what gets
# scraped (§14.2's two pods, no metrics server in `worker` yet).
#
# **Gauges are computed fresh on every scrape**, via `Yabeda.collect`, from
# Postgres rather than from in-process counters. `quality_breach` and
# `item_remade` events (§9.6, §5.2) are logged by `SweepQualityBreachesJob`,
# which runs on `worker` — a counter incremented there would sit in a
# process nobody scrapes and never reach Prometheus at all. Reading the
# running total from `scheduler_events` at scrape time sidesteps that
# entirely: whichever `web` pod answers the scrape queries the same database
# every other pod would, so there's nothing process-local to go stale or
# diverge. `queue_depth` and `concurrent_large_order_rate` are read the same
# way for the same reason, even though today's sources for those happen to
# run in `web` too — consistency here is worth more than the difference.
Yabeda.configure do
  group :boba_gals

  # §10.4: "Wait percentiles by size class" — the fairness claim itself.
  # Bucketed in seconds; §10.4's own headline is read at p90.
  histogram :order_wait_seconds,
            comment: "Customer wait (ready_at - placed_at) for a completed order",
            tags: %i[store size_class],
            buckets: [ 60, 120, 180, 300, 450, 600, 900, 1800, 3600 ]

  # §10.4: "ETA error... and bias (signed mean)" — bias is the one that
  # destroys trust (§7.3). Signed, not absolute: negative means early,
  # positive means late.
  histogram :eta_signed_error_seconds,
            comment: "Actual wait minus quoted_wait_seconds for a completed order",
            tags: %i[store],
            buckets: [ -300, -120, -60, -30, -15, 0, 15, 30, 60, 120, 300, 600 ]

  # §9.4's KDS header figure, exported as-is.
  gauge :queue_depth,
        comment: "Drinks (order_items) currently queued, not yet started",
        tags: %i[store]

  # The live analogue of the simulator's `large_order_rate` arrival-mix
  # parameter (§10.3, §11's acceptance criteria sweep it 0-12%): fraction of
  # currently open orders (§5.1's `Order.live`) that are large (§10.4's "7+"
  # class), rather than a swept input, since production can't set the mix —
  # only observe it. Pairs with `order_wait_seconds`'s small-order p90 on the
  # §10.4 headline panel.
  gauge :concurrent_large_order_rate,
        comment: "Fraction of currently open orders with 7+ drinks",
        tags: %i[store]

  # §9.6, §10.4. Not a Yabeda::Counter — see the file comment above for why.
  gauge :quality_breaches,
        comment: "Total drinks ever logged as a quality breach (scheduler_events)",
        tags: %i[store]

  # §5.2, §10.4's remake-latency motivation. Same reasoning as quality_breaches.
  gauge :remakes,
        comment: "Total remake drinks ever created (scheduler_events)",
        tags: %i[store]
end

Yabeda.collect do
  Store.find_each do |store|
    Yabeda.boba_gals.queue_depth.set(
      { store: store.id },
      OrderItem.joins(:order).where(orders: { store_id: store.id }, status: "queued").count
    )

    live_orders = store.orders.live.includes(:order_items)
    open_count = live_orders.size
    if open_count.positive?
      large_count = live_orders.count { |order| order.size_class == "7+" }
      Yabeda.boba_gals.concurrent_large_order_rate.set({ store: store.id }, large_count.to_f / open_count)
    end

    Yabeda.boba_gals.quality_breaches.set(
      { store: store.id },
      SchedulerEvent.where(store: store, event_type: "quality_breach").count
    )
    Yabeda.boba_gals.remakes.set(
      { store: store.id },
      SchedulerEvent.where(store: store, event_type: "item_remade").count
    )
  end
end

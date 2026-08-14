# Detects drinks that have sat finished past the quality limit and logs each
# breach exactly once (§9.6).
#
# Pickup is not tracked live (ADR-0005), so §9.6's "measures now - finished_at
# until picked_up_at" cannot be observed here the way the simulator observes
# it — there is no pickup event to stop the clock. Scoped to orders still
# `partially_ready` for exactly that reason: a barista does not hand over half
# an order, so a finished drink whose order is still waiting on a sibling
# *cannot* have been collected yet — "still sitting" is a fact there, not a
# guess. Once every drink in an order finishes and it reaches `ready`,
# whether it's still sitting or already gone is unknowable without a pickup
# signal, and kiosk/web pickup delays (§10.3) are usually under the quality
# limit, not over it — flagging there would mostly be measuring how fast
# people walk, not how long a drink actually sat (ADR-0024). A drink is only
# ever flagged once: existence of a prior `quality_breach` event for the same
# item is what keeps a periodic sweep from re-logging it forever.
#
# The limit itself is size-aware (§9.6, #80, ADR-0031): a flat
# quality_limit_seconds treats a 6-drink order's ordinary spread as an outlier,
# because it typically is several times over 300s (ADR-0014). Each item is
# checked against QualitySpreadStat's learned threshold for its order's size
# class once confident, or a seeded multiplier over quality_limit_seconds
# until then — see QualitySpreadStat::SEEDED_MULTIPLIERS.
class SweepQualityBreaches
  # @param store [Store]
  # @return [Array<OrderItem>] items newly logged as breached this run
  def self.call(store)
    new(store).call
  end

  def initialize(store)
    @store = store
    @default_limit_seconds = store.effective_scheduler_config["quality_limit_seconds"]
    @spread_stats = QualitySpreadStat.where(store: store).index_by(&:size_class)
  end

  # @return [Array<OrderItem>]
  def call
    candidates.select { |item| overdue?(item) }.map { |item| record(item) }
  end

  private

  # No SQL time filter here on purpose: a size class's threshold can be
  # *tighter* than the flat quality_limit_seconds default (a 2-drink order's
  # seeded multiplier is 0.5x), so prefiltering by the flat number in SQL
  # would drop items that now breach a tighter class threshold before they are
  # ever evaluated. Volume is bounded by real in-flight work — the same
  # property `Order#countable_items` relies on — so the per-item Ruby-side
  # check costs nothing that matters.
  def candidates
    already_logged = SchedulerEvent.where(store: @store, event_type: "quality_breach").select(:order_item_id)

    OrderItem
      .joins(:order)
      .includes(:order)
      .where(orders: { store_id: @store.id, status: "partially_ready" })
      .where(status: "finished")
      .where.not(id: already_logged)
  end

  def overdue?(item)
    Time.current - item.finished_at >= limit_for(item.order)
  end

  def limit_for(order)
    stat = @spread_stats[order.size_class]
    return stat.threshold_seconds if stat&.confident?

    @default_limit_seconds * QualitySpreadStat::SEEDED_MULTIPLIERS.fetch(order.size_class, 1.0)
  end

  def record(item)
    limit = limit_for(item.order)

    SchedulerEvent.record!(
      store: @store,
      event_type: "quality_breach",
      order_item: item,
      payload: { seconds_over: (Time.current - item.finished_at - limit).round }
    )
    item
  end
end

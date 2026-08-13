# Detects drinks that have sat finished past the quality limit and logs each
# breach exactly once (§9.6).
#
# Pickup is not tracked live (ADR-0005), so §9.6's "measures now - finished_at
# until picked_up_at" cannot be observed here the way the simulator observes
# it — there is no pickup event to stop the clock. A drink that is still
# finished this long later has already gone stale whether or not someone
# collected it in between, so sitting time is measured against `now` instead,
# and a drink is only ever flagged once: existence of a prior `quality_breach`
# event for the same item is what keeps a periodic sweep from re-logging it
# forever.
class SweepQualityBreaches
  # @param store [Store]
  # @return [Array<OrderItem>] items newly logged as breached this run
  def self.call(store)
    new(store).call
  end

  def initialize(store)
    @store = store
    @limit_seconds = store.effective_scheduler_config["quality_limit_seconds"]
  end

  # @return [Array<OrderItem>]
  def call
    candidates.find_each.map { |item| record(item) }
  end

  private

  def candidates
    already_logged = SchedulerEvent.where(store: @store, event_type: "quality_breach").select(:order_item_id)

    OrderItem
      .joins(:order)
      .where(orders: { store_id: @store.id })
      .where(status: "finished")
      .where(finished_at: ..(Time.current - @limit_seconds))
      .where.not(id: already_logged)
  end

  def record(item)
    SchedulerEvent.record!(
      store: @store,
      event_type: "quality_breach",
      order_item: item,
      payload: { seconds_over: (Time.current - item.finished_at - @limit_seconds).round }
    )
    item
  end
end

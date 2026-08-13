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
      .where(orders: { store_id: @store.id, status: "partially_ready" })
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

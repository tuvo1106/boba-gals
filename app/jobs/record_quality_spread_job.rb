# Folds an order's ready spread into the EWMA (§9.6, #80) — a full KDS undo
# window (§5.2) after it reaches `ready`, rather than at the moment it does.
#
# Same reasoning as `RecordPrepTimeJob` (ADR-0019): an EWMA can't be cleanly
# un-blended, and the KDS undo can move an order back out of `ready`. So
# nothing is learned until there is nothing left to undo.
class RecordQualitySpreadJob < ApplicationJob
  queue_as :default

  # @param order_id [Integer]
  # @param ready_at [Time] the ready transition this job was enqueued for
  # @return [void]
  def perform(order_id, ready_at)
    order = Order.find_by(id: order_id)
    return if order.nil?

    return unless still_the_same_ready?(order, ready_at)

    RecordQualitySpread.new.call(order)
  end

  private

  # Re-read here, not trusted from the enqueue, because the whole point of the
  # delay is that the order can have moved in the meantime (§5.2).
  #
  # `ready_at` is the token that makes this exactly-once, same idiom as
  # `RecordPrepTimeJob#still_the_same_finish?`. An undo moves the order back to
  # `partially_ready` and clears `ready_at` (`RollUpOrderStatus#apply`), so an
  # undone ready simply matches nothing here — no separate discard logic
  # needed. A re-finish that reaches `ready` again stamps a new `ready_at` and
  # enqueues its own job, so only the job carrying the surviving stamp records.
  def still_the_same_ready?(order, ready_at)
    order.status == "ready" && order.ready_at == ready_at
  end
end

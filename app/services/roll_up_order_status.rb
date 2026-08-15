# Derives an order's status from its drinks (§5.1).
#
# The order is only a container (§2), so its status is never set directly — it
# is always recomputed from the items. That keeps `partially_ready` honest, and
# it is what lets the KDS undo (§5.2) move an order back from `ready` without
# any special-case reversal logic.
class RollUpOrderStatus
  # Cancelled drinks don't count toward readiness, and a failed drink has
  # already produced a remake row that does.
  COUNTED_STATUSES = %w[queued in_progress finished].freeze

  # @param order [Order]
  # @return [Order]
  def call(order)
    items = order.order_items.where(status: COUNTED_STATUSES)
    return order if items.empty?

    finished = items.count { |i| i.status == "finished" }
    started  = items.any? { |i| i.status != "queued" }

    status =
      if finished == items.size then "ready"
      elsif finished.positive?  then "partially_ready"
      elsif started             then "in_progress"
      else "placed"
      end

    apply(order, status, finished)
  end

  private

  def apply(order, status, finished_count)
    attrs = { status: status }

    # first_ready_at anchors the quality timer and the cohesion spread metric
    # (§9.6, §10.4): how long the earliest drink sat while the rest were made.
    # Cleared when nothing is finished any more, symmetrically with `ready_at`
    # below and for the same reason: an undo can take the only finished drink
    # back, and a `first_ready_at` left behind is an anchor for output that is
    # no longer sitting. It feeds the scheduler's staleness boost via
    # `SchedulerStateStore` and the learned spread via `RecordQualitySpread`,
    # so a stale one both boosts a flow with nothing waiting and inflates the
    # eventual observation by the whole undo-and-remake gap.
    if finished_count.positive?
      attrs[:first_ready_at] = Time.current if order.first_ready_at.nil?
    else
      attrs[:first_ready_at] = nil
    end

    if status == "ready"
      attrs[:ready_at] = Time.current if order.ready_at.nil?
    else
      # An undo can move an order back out of ready; the timestamp has to go
      # with it, or the quality timer keeps counting from a moment that is no
      # longer true (§5.2).
      attrs[:ready_at] = nil
    end

    order.update!(attrs)
    order
  end
end

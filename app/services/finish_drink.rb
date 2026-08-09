# Marks a drink finished (§9.4) and re-derives its order's status.
#
# `finished` is terminal (§5.2). A drink that was genuinely made and is wrong is
# a remake — a new row — never a reversal of this one. The only exception is the
# 60-second undo, which corrects a mistap rather than a drink (UndoLastAction).
class FinishDrink
  Result = Struct.new(:success?, :item, :error, keyword_init: true)

  # @param item [OrderItem]
  # @return [FinishDrink::Result]
  def call(item)
    return failure("drink is not in progress") unless item.status == "in_progress"

    item.update!(status: "finished", finished_at: Time.current)

    SchedulerEvent.record!(
      store: item.order.store,
      event_type: "item_finished",
      order_item: item,
      payload: {
        station_id: item.station_id,
        barista_id: item.barista_id,
        observed_seconds: (item.finished_at - item.started_at).round
      }
    )

    # §7.3 learns from `finished_at - started_at`, so this is the only moment
    # the observation exists. Outliers are rejected inside the recorder rather
    # than here — a barista who forgot to tap "finish" is a data problem, not a
    # reason to fail the transition they did make.
    RecordPrepTime.new.call(item)

    order = RollUpOrderStatus.new.call(item.order)

    if order.status == "ready"
      SchedulerEvent.record!(store: order.store, event_type: "order_ready",
                             payload: { order_id: order.id })

      # §9.7's single message. Enqueued, never sent inline: it must never block
      # or fail the transition, and this method is the transition. The job
      # re-checks eligibility and claims the send atomically, because `ready` is
      # reachable more than once — the KDS undo (§5.2) can move an order back
      # out of it and a re-finish re-enters it.
      SendReadySmsJob.perform_later(order.id)
    end

    BroadcastStoreViews.call(order.store)
    Result.new(success?: true, item: item)
  end

  private

  def failure(message)
    Result.new(success?: false, error: message)
  end
end

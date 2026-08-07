# Claims the next drink for a station (§8).
#
# Two baristas will tap "start" at the same instant. `FOR UPDATE SKIP LOCKED`
# makes the second tap quietly receive the *next* drink instead of an error
# dialog, which removes most of the race conditions you would otherwise spend
# the project chasing.
#
# Build step 2 is FIFO: strict `queued_at, id`. Step 5 replaces the selection
# with `Scheduler.pick_next` over the same candidate set — the locking and the
# transaction boundary here do not change, only which candidate wins.
class ClaimNextDrink
  # Bounded so the lock is taken over a predictable slice rather than the whole
  # queue. Matches §8.
  CANDIDATE_LIMIT = 50

  # A claim can come back empty while drinks are still queued, because every
  # candidate it looked at was momentarily locked by a peer. That is a transient
  # condition, not an empty queue, and retrying is what keeps the promise in §8:
  # the second tap gets the next drink, never an error and never nothing.
  MAX_ATTEMPTS = 5

  # The retries have to span real time, not just repeat quickly.
  #
  # Without a wait, five attempts complete in well under a millisecond — far
  # inside a peer's open transaction, so the budget is spent before the row it
  # was waiting for is ever released, and the barista is told "nothing queued"
  # while drinks are visibly waiting. That is exactly the failure §8 forbids,
  # and it showed up as a flaky concurrency spec on CI while passing every time
  # on a fast machine with a local database.
  #
  # Linear growth with jitter: four baristas who tapped at the same instant must
  # not retry in lockstep, or they collide on every round. Worst case is roughly
  # 150ms of waiting before giving up, which is imperceptible at a counter and
  # orders of magnitude longer than the single UPDATE it is waiting on.
  BACKOFF_SECONDS = 0.01

  # @param station [Station]
  # @param barista [Barista]
  # @return [OrderItem, nil] the claimed drink, or nil when nothing is queued
  def call(station:, barista:)
    MAX_ATTEMPTS.times do |attempt|
      item = claim_once(station: station, barista: barista)

      if item
        # Outside the transaction, deliberately. Broadcasts and events never run
        # inside one (§8) — keep the lock window as short as the write itself.
        after_claim(item, station)
        return item
      end

      # Genuinely nothing to do, as opposed to losing every race this pass.
      return nil unless queued_remaining?(station)

      backoff(attempt)
    end

    nil
  end

  private

  # Only ever reached when this station lost every candidate to a peer, which
  # means the alternative to waiting is telling a barista the queue is empty
  # when it is not.
  def backoff(attempt)
    sleep(BACKOFF_SECONDS * (attempt + 1) * (0.5 + Kernel.rand))
  end

  def claim_once(station:, barista:)
    OrderItem.transaction do
      # Materialized deliberately: calling .first here would replace the batch
      # limit with LIMIT 1, and PostgreSQL applies LIMIT during the scan rather
      # than to the set it successfully locked. A contended row is skipped after
      # the limit is already spent, so the query returns nothing while unclaimed
      # drinks sit right behind it. Fetch the batch, then choose in Ruby — which
      # is also the shape §8 needs so step 5 can drop Scheduler.pick_next in.
      candidate = candidates(station).to_a.first
      next nil if candidate.nil?

      candidate.update!(
        status: "in_progress",
        station: station,
        barista: barista,
        started_at: Time.current
      )
      candidate
    end
  end

  # Non-locking, so it sees rows another transaction has locked but not yet
  # committed — exactly the case worth retrying for.
  def queued_remaining?(station)
    OrderItem.joins(:order)
             .where(orders: { store_id: station.store_id })
             .where(status: "queued")
             .exists?
  end

  # `SKIP LOCKED` is what makes this pod-agnostic (§14.4): two `web` pods running
  # this query concurrently never hand out the same drink, and neither blocks.
  def candidates(station)
    OrderItem
      .joins(:order)
      .where(orders: { store_id: station.store_id })
      .where(status: "queued")
      .order(:queued_at, :id)
      .limit(CANDIDATE_LIMIT)
      .lock("FOR UPDATE SKIP LOCKED")
  end

  def after_claim(item, station)
    SchedulerEvent.record!(
      store: station.store,
      event_type: "item_started",
      order_item: item,
      payload: { station_id: station.id, barista_id: item.barista_id, prep_seconds: item.prep_seconds }
    )

    RollUpOrderStatus.new.call(item.order)
    BroadcastStoreViews.call(station.store)
  end
end

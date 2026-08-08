# Claims the next drink for a station (§8), choosing it with the scheduler (§6).
#
# Selection and claiming are deliberately separate concerns:
#
# - **Which drink** is decided by `Scheduler.pick_next` — a pure function over a
#   snapshot, with no locks held and no database access of its own (§6.2).
# - **Whether this station gets it** is decided by one conditional UPDATE, which
#   Postgres makes atomic. Two baristas tapping at the same instant resolve
#   there: exactly one update matches, and the loser retries and is handed the
#   next drink rather than an error (§8).
#
# Step 2 shipped this as `SELECT ... FOR UPDATE SKIP LOCKED` over a candidate
# batch, because FIFO's choice *was* "the first unlocked row". Now the scheduler
# names a specific drink, so the question changes from "which row can I lock" to
# "is this row still queued" — and a guarded UPDATE answers that without holding
# a transaction open across the scheduler's work.
class ClaimNextDrink
  # A claim can lose to a peer that took the same drink microseconds earlier.
  # That is transient, not an empty queue, and retrying is what keeps §8's
  # promise: the second tap gets the next drink, never an error and never
  # nothing.
  MAX_ATTEMPTS = 5

  # The retries have to span real time, not just repeat quickly (§8). Without a
  # wait, five attempts complete in under a millisecond — inside the window a
  # peer's transaction is still open — and the barista is told the queue is
  # empty while drinks are visibly waiting.
  BACKOFF_SECONDS = 0.01

  # @param station [Station]
  # @param barista [Barista]
  # @return [OrderItem, nil] the claimed drink, or nil when nothing is queued
  def call(station:, barista:)
    store = station.store
    state_store = SchedulerStateStore.new(store)

    MAX_ATTEMPTS.times do |attempt|
      state = state_store.load
      picked = Scheduler.pick_next(state, Time.current)

      return nil if picked.nil?

      item = claim(picked[:item].id, station: station, barista: barista)

      if item
        # Only persisted on a successful claim. A lost race must not bank the
        # deficit it drew down, or the winner's drink is paid for twice.
        state_store.save(state)
        after_claim(item, station)
        return item
      end

      backoff(attempt)
    end

    nil
  end

  private

  # One statement, no transaction, no lock held. `status: "queued"` in the WHERE
  # clause is the whole concurrency control: Postgres serialises the two updates
  # and the second matches zero rows.
  def claim(item_id, station:, barista:)
    now = Time.current

    updated = OrderItem.where(id: item_id, status: "queued")
                       .update_all(status: "in_progress", station_id: station.id,
                                   barista_id: barista.id, started_at: now,
                                   updated_at: now)

    OrderItem.find(item_id) if updated == 1
  end

  def backoff(attempt)
    sleep(BACKOFF_SECONDS * (attempt + 1) * (0.5 + Kernel.rand))
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

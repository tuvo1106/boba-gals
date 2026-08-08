# Recomputes a store's projected ETAs and pushes them to the board (§7.2).
#
# §7.2's triggers: order placed, item started or finished, remake created,
# station activated or deactivated, and an idle tick every 30s that catches
# drift from drinks running longer than their estimate.
#
# "Debounced to at most one run per store per 2 seconds. The debounce must be a
# Redis lock (`SET ... NX PX`), not in-process state — web pods come in pairs
# (§14.4)." Two pods with independent in-process windows debounce to 2 per
# window and neither can see the other's pending run.
#
# Leading edge with a trailing flush rather than a plain drop, matching
# `BoardBroadcast` (§9.2). A dropping debounce loses whichever trigger lands
# last in a burst, and the last one is the one that reflects what the shop
# actually looks like now — a customer would see the ETA from midway through the
# burst until the 30s tick corrected it.
class RecomputeEta
  # §7.2: "at most one run per store per 2 seconds".
  WINDOW = 2.seconds

  # Long enough to outlive the flush job's queue latency, short enough that a
  # crashed worker cannot suppress recomputes for more than a few seconds.
  PENDING_TTL = 15.seconds

  # @param store [Store]
  # @return [void]
  def self.call(store)
    if open_window?(store)
      recompute(store)
    else
      schedule_flush(store)
    end
  end

  # The trailing edge, called only by `RecomputeEtaJob` — it recomputes
  # unconditionally, because the whole point is that the window was closed when
  # the trigger fired.
  #
  # @param store [Store]
  # @return [void]
  def self.flush(store)
    BobaGals::REDIS.with { |redis| redis.del(pending_key(store)) }
    open_window?(store)
    recompute(store)
  end

  # Projects, caches, and pushes the board. The board broadcast has its own
  # 1/sec throttle (§9.2) and is left to apply it.
  #
  # @param store [Store]
  # @return [void]
  def self.recompute(store)
    EtaCache.write(store, ProjectEta.for_open_orders(store))
    BoardBroadcast.call(store)
  end

  # `SET NX PX` is atomic across pods — exactly one caller in any 2-second
  # window gets a true back, and the key expires on its own so a crashed worker
  # cannot wedge ETAs permanently stale.
  def self.open_window?(store)
    BobaGals::REDIS.with do |redis|
      redis.set(window_key(store), 1, nx: true, px: WINDOW.in_milliseconds)
    end
  end

  # Also `SET NX`, so fifty transitions inside one window enqueue one flush
  # rather than fifty.
  def self.schedule_flush(store)
    claimed = BobaGals::REDIS.with do |redis|
      redis.set(pending_key(store), 1, nx: true, px: PENDING_TTL.in_milliseconds)
    end

    RecomputeEtaJob.set(wait: WINDOW).perform_later(store.id) if claimed
  end

  def self.window_key(store)
    BobaGals.redis_key("eta", "throttle", store.id)
  end

  def self.pending_key(store)
    BobaGals.redis_key("eta", "pending", store.id)
  end

  private_class_method :open_window?, :schedule_flush, :window_key, :pending_key
end

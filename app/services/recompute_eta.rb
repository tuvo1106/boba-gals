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
      reproject(store)
    else
      schedule_flush(store)
    end

    # Always, outside the window check. The projection is debounced at 2s and
    # the board at 1s (§9.2) — different rates, so gating the board on the ETA's
    # window subordinates one to the other, and a transition landing inside the
    # ETA window produced no board update at all.
    #
    # It is also what keeps the board alive when Sidekiq is not: the trailing
    # recompute and the 30s idle tick both run on the worker, so if the board
    # only moved when they did, a dead worker would freeze it silently. This
    # path is inline, and the worst case is a board showing an ETA up to two
    # seconds old — which no customer can perceive and no barista depends on.
    BoardBroadcast.call(store)
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
    reproject(store)
    BoardBroadcast.call(store)
  end

  # The expensive half: run the projection and cache it. Publishing is the
  # caller's business, because the board runs on its own schedule.
  #
  # @param store [Store]
  # @return [void]
  def self.reproject(store)
    EtaCache.write(store, ProjectEta.for_open_orders(store))
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

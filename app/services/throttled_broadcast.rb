# The leading-edge-with-trailing-flush throttle shared by the customer-facing
# broadcasts (§9.2).
#
# Extracted from `BoardBroadcast` when `OrderChannel` needed the identical
# mechanism. Both push a view that every drink transition changes, both are
# watched by someone standing in the shop waiting on the answer, and both must
# not drop the *last* event in a burst — which is the one that says the drink is
# ready.
#
# The window lives in Redis rather than in a class variable because `web` runs
# two replicas (§14.2, §14.4): two pods with independent in-process windows
# throttle to 2/sec, and neither can see the other's pending flush.
#
# `extend` this and supply `throttle_name`, `window`, `pending_ttl`,
# `flush_job`, and `publish`.
module ThrottledBroadcast
  # @param store [Store]
  # @return [void]
  def call(store)
    if open_window?(store)
      publish(store)
    else
      schedule_flush(store)
    end
  end

  # The trailing edge, called only by the flush job. It publishes
  # unconditionally — the whole point of the flush is that the window was closed
  # when the change happened.
  #
  # @param store [Store]
  # @return [void]
  def flush(store)
    BobaGals::REDIS.with { |redis| redis.del(pending_key(store)) }

    # Re-arms the window, so this flush counts as its second's broadcast and a
    # transition landing immediately after schedules a fresh trailing flush
    # rather than publishing on top of this one.
    open_window?(store)

    publish(store)
  end

  private

  # `SET NX PX` is atomic across pods — exactly one caller in any given window
  # gets a true back, and the key expires on its own, so a crash cannot wedge
  # the broadcast shut.
  def open_window?(store)
    BobaGals::REDIS.with do |redis|
      redis.set(window_key(store), 1, nx: true, px: window.in_milliseconds)
    end
  end

  # Also `SET NX`, so a burst of fifty transitions in one window enqueues one
  # flush rather than fifty.
  def schedule_flush(store)
    claimed = BobaGals::REDIS.with do |redis|
      redis.set(pending_key(store), 1, nx: true, px: pending_ttl.in_milliseconds)
    end

    flush_job.set(wait: window).perform_later(store.id) if claimed
  end

  def window_key(store)
    BobaGals.redis_key(throttle_name, "throttle", store.id)
  end

  def pending_key(store)
    BobaGals.redis_key(throttle_name, "pending", store.id)
  end
end

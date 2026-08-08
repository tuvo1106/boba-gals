# The projected ETAs a board broadcast reads (DESIGN.md §7.2).
#
# §7.2 debounces the *recompute* to one run per store per 2 seconds; §9.2
# throttles the *board broadcast* to one per second. Those are different rates,
# so the two cannot be the same operation — the board publishes twice as often
# as the projection is allowed to run, and reads the most recent result.
#
# That separation is what keeps `ProjectEta` off the request path entirely.
# Measured on the compose stack, the projection is 3.6ms at 16 queued drinks but
# 175ms at 436 and 871ms at 1186 — it is O(n^2 log n)-ish, because
# `priority_ring` sorts on every dispatch (ADR-0012). Running that inline in the
# request that placed an order is a latency bug waiting for a busy Saturday.
#
# Redis rather than Rails.cache: `web` runs two replicas (§14.2), and a
# per-process cache means two pods showing two different boards.
class EtaCache
  # Longer than the 30s idle tick (§7.2) so a healthy store always has a warm
  # entry, short enough that a store whose worker died shows a stale number for
  # seconds rather than for a shift.
  TTL = 90.seconds

  # @param store [Store]
  # @return [Hash{Integer => Integer}, nil] order id => seconds, or nil when cold
  def self.read(store)
    raw = BobaGals::REDIS.with { |redis| redis.get(key(store)) }
    return nil if raw.nil?

    JSON.parse(raw).transform_keys(&:to_i)
  rescue JSON::ParserError
    # A malformed entry is not worth failing a board render over — treat it as
    # cold and let the next recompute overwrite it.
    nil
  end

  # @param store [Store]
  # @param estimates [Hash{Integer => Integer}]
  # @return [Hash{Integer => Integer}] the estimates, for chaining
  def self.write(store, estimates)
    BobaGals::REDIS.with do |redis|
      redis.set(key(store), estimates.to_json, ex: TTL.to_i)
    end

    estimates
  end

  # Cold-start path: the first board render after a deploy has no cached entry
  # and still owes a number, so it projects inline once and warms the cache.
  #
  # @param store [Store]
  # @return [Hash{Integer => Integer}]
  def self.fetch(store, now: Time.current)
    read(store) || write(store, ProjectEta.for_open_orders(store, now: now))
  end

  def self.key(store)
    BobaGals.redis_key("eta", store.id)
  end

  private_class_method :key
end

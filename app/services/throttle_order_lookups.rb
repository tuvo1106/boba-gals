# Closes the websocket door to pickup-code enumeration that §13.2's Rack::Attack throttles
# do not reach (issue #39).
#
# `GET /api/v1/orders/:pickup_code` and `OrderChannel#subscribed` are two doors to the same
# room, both authorized by the pickup code alone (§13.1). Rack::Attack sees a websocket
# upgrade as a single HTTP request, so once a connection is open it cannot see the
# `subscribe` messages that follow it — a single connection could otherwise retry an
# unbounded number of codes. This gives the channel the same per-IP budget as its REST
# mirror (`status/ip`, config/initializers/rack_attack.rb): 60 per minute.
#
# Counted in Redis, not a class variable, for the same reason as `ThrottledBroadcast`: `web`
# runs 2 pods (§14.2), and an in-process counter would let each pod grant its own 60.
#
# Counts failed lookups only. A lookup that succeeds isn't the thing being guarded against,
# and a customer with several tabs open behind one NAT'd IP shouldn't spend the same budget
# as someone guessing codes.
class ThrottleOrderLookups
  LIMIT = 60
  PERIOD = 1.minute

  class << self
    # @param remote_ip [String]
    # @return [Boolean] true once this IP has failed LIMIT lookups within PERIOD
    def exceeded?(remote_ip)
      count(remote_ip) >= LIMIT
    end

    # Records a failed lookup against the limit `exceeded?` checks.
    #
    # @param remote_ip [String]
    # @return [void]
    def record_failure(remote_ip)
      BobaGals::REDIS.with do |redis|
        new_count = redis.incr(key(remote_ip))
        redis.expire(key(remote_ip), PERIOD) if new_count == 1
      end
    end

    private

    def count(remote_ip)
      BobaGals::REDIS.with { |redis| redis.get(key(remote_ip)).to_i }
    end

    def key(remote_ip)
      BobaGals.redis_key("order_channel", "failed_lookups", remote_ip)
    end
  end
end

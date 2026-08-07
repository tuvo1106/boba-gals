require "connection_pool"

module BobaGals
  # Redis as load-bearing infrastructure, not a cache (DESIGN.md Rails 8 note).
  #
  # ActionCable has its own connection via config/cable.yml; this pool is for
  # everything the application does with Redis directly — the board broadcast
  # throttle (§9.2), and later the ETA debounce lock (§7.2), scheduler deficits
  # and the ring pointer (§6.5).
  #
  # All of those exist because `web` runs 2 replicas from the first deploy
  # (§14.2). In-process state would work on one pod and silently diverge on two.
  REDIS = ConnectionPool.new(size: Integer(ENV.fetch("RAILS_MAX_THREADS", 5)), timeout: 5) do
    Redis.new(url: ENV.fetch("REDIS_URL") { "redis://localhost:6379/1" })
  end

  # Every key this application writes carries an environment prefix, the same
  # way ActionCable's `channel_prefix` does. Development and test share a Redis
  # in compose and in CI, and an unprefixed `board:throttle:1` would collide
  # between them the moment two store ids matched.
  #
  # @param parts [Array<String, Integer>]
  # @return [String] namespaced key, e.g. "boba_gals_test:board:throttle:7"
  def self.redis_key(*parts)
    "boba_gals_#{Rails.env}:#{parts.join(':')}"
  end
end

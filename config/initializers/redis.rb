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
  # Explicit socket timeouts, not the driver's defaults. `/readyz` pings this
  # pool on every kubelet probe (ReadinessController::TIMEOUT_SECONDS), and an
  # unbounded read against a Redis that accepts connections but stops answering
  # holds a Puma thread for as long as the driver is willing to wait — which on
  # a 5-thread pod probed every 5s is how probes pile up on a pod that is
  # already struggling.
  #
  # Two seconds matches the readiness budget. Everything else this pool does is
  # a sub-millisecond op against a Redis in the same cluster, so a request that
  # has not answered in two seconds is not slow, it is gone.
  REDIS_TIMEOUT_SECONDS = 2

  REDIS = ConnectionPool.new(size: Integer(ENV.fetch("RAILS_MAX_THREADS", 5)), timeout: 5) do
    Redis.new(
      url: ENV.fetch("REDIS_URL") { "redis://localhost:6379/1" },
      connect_timeout: REDIS_TIMEOUT_SECONDS,
      read_timeout: REDIS_TIMEOUT_SECONDS,
      write_timeout: REDIS_TIMEOUT_SECONDS
    )
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

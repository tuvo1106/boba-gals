# Redis is load-bearing (§14.4), so the suite talks to a real one rather than a
# fake. The board's broadcast throttle is a `SET NX PX` lock whose whole purpose
# is to behave correctly across two `web` pods — a stub would assert that the
# code calls Redis, which is not the property worth testing.
#
# Keys are namespaced per environment by BobaGals.redis_key, so a test run
# cannot disturb the development keyspace even on a shared server.
RSpec.configure do |config|
  # Redis does not roll back.
  #
  # Transactional specs roll the database back, so ids repeat on every run —
  # and scheduler deficits are keyed by store and order id with a 6-hour TTL
  # (§6.5). Without this, run N inherits run N-1's deficits for the same ids and
  # the scheduler makes choices no example set up. It surfaced as a flow being
  # dispatched with a deficit of 495 seconds that nothing in the spec created.
  #
  # Scoped to this environment's namespace, so a developer's running app is
  # untouched.
  config.before do
    BobaGals::REDIS.with do |redis|
      keys = redis.scan_each(match: BobaGals.redis_key("*")).to_a
      redis.del(*keys) if keys.any?
    end
  end

  config.before(:suite) do
    BobaGals::REDIS.with(&:ping)
  rescue Redis::BaseConnectionError => e
    abort <<~MESSAGE
      Cannot reach Redis at #{ENV.fetch('REDIS_URL', 'redis://localhost:6379/1')}: #{e.message}

      The suite needs it for the board broadcast throttle (§9.2) and, from build
      step 5, for scheduler state (§6.5). Start it with:

        docker compose up -d redis
    MESSAGE
  end
end

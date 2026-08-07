# Redis is load-bearing (§14.4), so the suite talks to a real one rather than a
# fake. The board's broadcast throttle is a `SET NX PX` lock whose whole purpose
# is to behave correctly across two `web` pods — a stub would assert that the
# code calls Redis, which is not the property worth testing.
#
# Keys are namespaced per environment by BobaGals.redis_key, so a test run
# cannot disturb the development keyspace even on a shared server.
RSpec.configure do |config|
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

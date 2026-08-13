# Rate limiting (§13.2). The three throttles and the kiosk safelist are
# specified verbatim in DESIGN.md; this file is that spec, not a
# reinterpretation of it.
Rails.application.config.middleware.use Rack::Attack

# The default store is per-process memory, which would let each of the 2 `web`
# pods (§14.2) grant its own 10/min instead of enforcing one limit across
# both. Redis is already load-bearing (§ Rails 8 note), so counters live there
# instead — namespaced the same way BobaGals.redis_key namespaces every other
# key (config/initializers/redis.rb, loaded after this file alphabetically, so
# the format is duplicated here rather than referenced), so dev and test
# (which share one Redis in compose) can't cross-count and the test suite's
# per-example Redis flush (spec/support/redis.rb) clears these counters along
# with everything else.
Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV.fetch("REDIS_URL") { "redis://localhost:6379/1" },
  namespace: "boba_gals_#{Rails.env}:rack_attack"
)

# A busy Saturday from the store's own kiosk would otherwise trip the order
# throttle below — this exempts it, and only it.
Rack::Attack.safelist("kiosk") do |req|
  ENV.fetch("KIOSK_IPS", "").split(",").include?(req.ip)
end

Rack::Attack.throttle("orders/ip", limit: 10, period: 1.minute) do |req|
  req.ip if req.post? && req.path == "/api/v1/orders"
end

Rack::Attack.throttle("status/ip", limit: 60, period: 1.minute) do |req|
  req.ip if req.path.start_with?("/api/v1/orders/")
end

Rack::Attack.throttle("kds_pin/ip", limit: 10, period: 1.minute) do |req|
  req.ip if req.path == "/api/v1/kds/session"
end

# JSON, not Rack::Attack's default plain-text body — this is an API-only app
# (§ config.api_only) and every other error response here is `{ error: }`
# (ApplicationController's siblings, e.g. Api::V1::BaseController#not_found).
Rack::Attack.throttled_responder = lambda do |req|
  match_data = req.env["rack.attack.match_data"]
  reset_at = match_data[:epoch_time] + match_data[:period]

  headers = {
    "Content-Type" => "application/json",
    "RateLimit-Limit" => match_data[:limit].to_s,
    "RateLimit-Remaining" => "0",
    "RateLimit-Reset" => reset_at.to_s,
    "Retry-After" => (reset_at - Time.now.to_i).to_s
  }

  [ 429, headers, [ { error: "rate limit exceeded" }.to_json ] ]
end

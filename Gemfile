source "https://rubygems.org"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"

# Redis is load-bearing, not a cache (DESIGN.md Rails 8 note): scheduler deficits
# and ring pointer (§6.5), the ETA debounce lock (§7.2), and ActionCable pub/sub
# across pods (§14.4). This is why the Solid defaults are skipped.
gem "redis", "~> 6.0"

# Background jobs: Sidekiq, not Solid Queue (§14.1). Recurring work — the ETA
# idle tick (§7.2), abandoned-order sweep (§5.1), quality-timer checks (§9.6) —
# runs via sidekiq-cron, never cron in a container.
gem "sidekiq", "~> 8.1"
gem "sidekiq-cron", "~> 2.4"

# KDS barista PINs and the admin password (§13.3, §13.4).
gem "bcrypt", "~> 3.1.7"

# The React app is served from a different origin in development (Vite on 5173).
gem "rack-cors", "~> 3.0"

gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "bootsnap", require: false

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false

  gem "rspec-rails", "~> 8.0"
  gem "factory_bot_rails", "~> 6.5"
end

group :test do
  gem "shoulda-matchers", "~> 8.0"
  gem "simplecov", "~> 1.0", require: false
end

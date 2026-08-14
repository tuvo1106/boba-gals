source "https://rubygems.org"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"

# The DRR scheduler (§6), extracted from app/scheduler in ADR-0033. A path gem
# rather than a published one: the only consumer is this app plus its simulator,
# and the payoff is the boundary rather than reuse — the gemspec declares zero
# runtime dependencies, which enforces "the scheduler must not require Rails"
# at the packaging level instead of by convention. It speaks a domain-neutral
# vocabulary (cost, expedited, deadline); `BuildSchedulerConfig` maps this app's
# persisted key names onto it.
gem "deficit_scheduler", path: "gems/deficit_scheduler"

# Redis is load-bearing, not a cache (DESIGN.md Rails 8 note): scheduler deficits
# and ring pointer (§6.5), the ETA debounce lock (§7.2), and ActionCable pub/sub
# across pods (§14.4). This is why the Solid defaults are skipped.
# Pinned to 5.x, not 6.x: ActionCable's Redis pub/sub adapter declares
# `redis >= 4, < 6`, and with a 6.x gem the adapter fails to load at runtime
# with a Gem::LoadError. Since §14.4 makes that adapter mandatory — without it
# broadcasts from one web pod never reach subscribers on another — this
# constraint is load-bearing, not cosmetic. spec/config/invariants_spec.rb
# fails if the two ever drift apart again.
gem "redis", "~> 5.0"

# Background jobs: Sidekiq, not Solid Queue (§14.1). Recurring work — the ETA
# idle tick (§7.2), abandoned-order sweep (§5.1), quality-timer checks (§9.6) —
# runs via sidekiq-cron, never cron in a container.
gem "sidekiq", "~> 8.1"
gem "sidekiq-cron", "~> 2.4"

# KDS barista PINs and the admin password (§13.3, §13.4).
gem "bcrypt", "~> 3.1.7"

# The React app is served from a different origin in development (Vite on 5173).
gem "rack-cors", "~> 3.0"

# Throttling (§13.2). Backed by Redis, not the default in-process store — `web`
# runs 2 pods from the start (§14.2), and a per-process counter would let each
# pod grant its own 10/min instead of enforcing one limit across both.
gem "rack-attack", "~> 6.7"

# Metrics (§15), scraped from /metrics by kube-prometheus-stack. `web` gets
# that route for free from config/routes.rb; `worker` runs no HTTP server at
# all, so yabeda-sidekiq's metrics need a standalone exporter thread started
# inside the worker process — see config/initializers/yabeda_sidekiq.rb and
# ADR-0026. `rackup`/`webrick` are what that standalone server runs on
# (Yabeda::Prometheus::Exporter.start_metrics_server!, not Puma).
gem "yabeda", "~> 0.16"
gem "yabeda-rails", "~> 0.11"
gem "yabeda-prometheus", "~> 0.9"
gem "yabeda-sidekiq", "~> 0.12"
gem "webrick", "~> 1.8"

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
  # Mutation testing over app/scheduler/** only (ADR-0002). 100% coverage on a
  # pure function proves nothing on its own — a surviving mutant is the real
  # signal. Free for public repositories, which is what unblocked it.
  gem "mutant", "~> 0.13", require: false
  gem "mutant-rspec", "~> 0.13", require: false

  gem "shoulda-matchers", "~> 8.0"
  gem "simplecov", "~> 1.0", require: false

  # Generates docs/api/openapi.yaml from the request specs below (ADR-0002,
  # ADR-0030). rswag-api/rswag-ui are deliberately not added — nothing here
  # serves the docs, this repo only generates them.
  gem "rswag-specs", "~> 2.16"
end

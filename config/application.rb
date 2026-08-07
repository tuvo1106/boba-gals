require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module BobaGals
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Sidekiq, not Solid Queue (§14.1). The `worker` service in compose and the
    # `worker` Deployment in the cluster run this same image with a Sidekiq
    # command, so anything enqueued here has somewhere to land.
    config.active_job.queue_adapter = :sidekiq

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Cookies and sessions, added back for /admin only (§13.4). Everything else
    # is stateless: the menu, board and health endpoints are public, the KDS
    # carries a bearer token (§13.3), and orders are addressed by pickup code.
    #
    # SameSite=Strict is the CSRF defence rather than a synchroniser token —
    # ADR-0006 records why. httponly keeps the session out of reach of any
    # script on the page; secure rides with production, which is also the only
    # environment with `force_ssl` and therefore any TLS to require.
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore,
                          key: "_boba_gals_admin",
                          same_site: :strict,
                          httponly: true,
                          secure: Rails.env.production?
  end
end

require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Deliberately *not* `assume_ssl` (§14.5). Assuming makes Rails treat every
  # request as secure whether or not it was, which is how the cluster spent its
  # first weeks handing browsers a `Secure` session cookie over plain http: the
  # cookie was silently dropped, admin sign-in worked under curl and could not
  # work in a browser, and nothing anywhere reported it. Reading
  # `X-Forwarded-Proto` from the ingress instead means an unterminated request
  # is redirected rather than served, so the failure is visible.
  config.assume_ssl = false

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # The probes are the exception, and they are not cosmetic. The kubelet reaches
  # the pod directly on :3000 with no `X-Forwarded-Proto`, so without this both
  # would be redirected — and a redirect counts as a *passing* probe, because
  # the kubelet treats any 2xx or 3xx as success. `/readyz` would then report
  # healthy while the database was down, which is precisely what ADR-0008 splits
  # the two probes to prevent. Excluding them keeps them answering with their
  # own status.
  config.ssl_options = {
    redirect: { exclude: ->(request) { request.path.in?(%w[/up /readyz]) } }
  }

  # ActionCable's origin check defaults to same-origin *over https*, derived
  # from the request host. That default is now satisfiable — the cluster serves
  # https (§14.5) — but it is still named explicitly, because the derivation
  # runs behind a terminating proxy and a wrong answer costs a websocket that
  # never connects, with the board and KDS falling back to a static first paint
  # that never updates. That is §14.4's failure mode reached by a different
  # route, and it is silent from the client's side.
  #
  # Comma-separated, and left at Rails' strict default when unset, so
  # forgetting it fails closed rather than open.
  allowed_cable_origins = ENV.fetch("ACTIONCABLE_ALLOWED_ORIGINS", "")
                             .split(",").map(&:strip).reject(&:empty?)
  config.action_cable.allowed_request_origins = allowed_cable_origins if allowed_cable_origins.any?

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # config.active_job.queue_adapter = :resque

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end

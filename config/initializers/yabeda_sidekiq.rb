# Starts a standalone Prometheus exporter inside the worker process (§15,
# ADR-0026). `web` gets /metrics for free from config/routes.rb, served by the
# same Puma process handling requests. `worker` runs no HTTP server at all —
# Sidekiq is a background process, not a Rack app — so without this,
# yabeda-sidekiq's metrics (job counts, queue latency, retries) would sit in a
# process nobody scrapes and never reach Prometheus, exactly the trap
# ADR-0025 already worked around for the business gauges.
#
# `Sidekiq.server?` is true only inside the actual sidekiq process, never when
# this same initializer loads as part of `web` booting the same Rails app —
# starting a second web server there would be a bug, not redundancy.
if defined?(Sidekiq) && Sidekiq.server?
  Yabeda::Prometheus::Exporter.start_metrics_server!
end

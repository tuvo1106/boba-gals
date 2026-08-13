# Recurring work runs through sidekiq-cron, never cron in a container (§14.1).
#
# Loaded on the server side only. Every `web` pod would otherwise register the
# same schedule, and while sidekiq-cron dedupes by name, having the API replicas
# own the schedule means a web-only rollout can silently change it.
Rails.application.config.after_initialize do
  next unless Sidekiq.server?

  Sidekiq::Cron::Job.create(
    name: "recompute-etas-idle-tick",
    # §7.2: "Idle tick every 30s (catches drift from slow drinks in progress)".
    # Nothing else fires while a barista is quietly making a 95-second drink, so
    # without this the board's countdown freezes between transitions.
    cron: "*/30 * * * * *",
    class: "RecomputeAllEtasJob"
  )

  Sidekiq::Cron::Job.create(
    name: "quality-breach-sweep",
    # Same cadence as the ETA idle tick: nothing else fires while a finished
    # drink just sits on the counter, so this is what notices it crossing
    # quality_limit_seconds (default 300s) (§9.6).
    cron: "*/30 * * * * *",
    class: "SweepQualityBreachesJob"
  )
end

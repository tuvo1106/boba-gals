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
end

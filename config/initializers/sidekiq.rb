# Every `set(wait:)` schedule in this app — the KDS undo window (§9.1), the ETA
# debounce (§7.2), and the board/order broadcast trailing flush (§9.2) — relies
# on Sidekiq's own scheduled-set poller rather than a bespoke one, on purpose:
# it is what lets the trailing flush survive the pod that scheduled it going
# away mid-rollout (see `BoardFlushJob`/`OrderFlushJob`).
#
# That poller defaults to checking Redis roughly once every
# `process_count * 5` seconds — tuned for retry-queue housekeeping, not for a
# throttle whose whole point is a ~1-second trailing edge. `worker` runs a
# single replica (§14.2), so the default resolves to an average 5s poll with
# up to 7.5s of jitter — measured on the compose stack at +7.25s (issue #40),
# against §9.2's "throttle board broadcasts to 1/sec".
#
# Pinned to 1s directly rather than left to scale off `worker`'s replica count,
# since `average_scheduled_poll_interval` would silently stop matching this
# comment's reasoning if that replica count ever changed for an unrelated
# reason. The three schedules above are the only consumers of Sidekiq's
# scheduled set in this app, so the wider poll on the shared retry set costs
# nothing distinguishable — a single `worker` checking Redis every ~1s instead
# of every ~5s.
Sidekiq.configure_server do |config|
  config[:poll_interval_average] = 1
end

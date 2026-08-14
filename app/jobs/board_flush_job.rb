# The trailing edge of the board's 1/sec broadcast throttle (§9.2).
#
# Runs on Sidekiq (§14.1), which is what makes the trailing flush survive the
# pod that scheduled it going away mid-rollout — an in-process timer would not.
# "1/sec" describes the window (`BoardBroadcast::WINDOW`), not a latency
# guarantee: this job only runs once Sidekiq's own scheduled-set poller notices
# it, so the actual trailing edge lands at `WINDOW` plus up to a poll interval
# of jitter (config/initializers/sidekiq.rb pins that to ~1s; issue #40 has the
# measurement from before it was tuned).
class BoardFlushJob < ApplicationJob
  queue_as :default

  # @param store_id [Integer]
  # @return [void]
  def perform(store_id)
    store = Store.find_by(id: store_id)
    return if store.nil?

    BoardBroadcast.flush(store)
  end
end

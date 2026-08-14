# The trailing edge of the order broadcasts' 1/sec throttle (§9.2).
#
# Runs on Sidekiq (§14.1), which is what makes the trailing flush survive the
# pod that scheduled it going away mid-rollout — an in-process timer would not.
# See `BoardFlushJob` for why "1/sec" describes the window, not this job's
# actual latency.
class OrderFlushJob < ApplicationJob
  queue_as :default

  # @param store_id [Integer]
  # @return [void]
  def perform(store_id)
    store = Store.find_by(id: store_id)
    return if store.nil?

    OrderBroadcast.flush(store)
  end
end

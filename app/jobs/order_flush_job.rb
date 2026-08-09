# The trailing edge of the order broadcasts' 1/sec throttle (§9.2).
#
# Runs on Sidekiq (§14.1), which is what makes the trailing flush survive the
# pod that scheduled it going away mid-rollout — an in-process timer would not.
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

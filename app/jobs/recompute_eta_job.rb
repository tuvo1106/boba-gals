# The trailing edge of §7.2's ETA recompute debounce, and the carrier for its
# 30-second idle tick.
#
# On Sidekiq (§14.1) rather than an in-process timer, which is what makes a
# pending recompute survive the pod that scheduled it going away mid-rollout.
class RecomputeEtaJob < ApplicationJob
  queue_as :default

  # @param store_id [Integer]
  # @return [void]
  def perform(store_id)
    store = Store.find_by(id: store_id)
    return if store.nil?

    RecomputeEta.flush(store)
  end
end

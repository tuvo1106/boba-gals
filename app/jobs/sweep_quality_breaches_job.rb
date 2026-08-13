# §9.6's other half of the ETA idle tick's problem: nothing fires while a
# finished drink just sits on the counter, so a periodic sweep is what finds
# it instead of a state transition (§7.2 closes the same gap for drinks still
# being made).
#
# Recurring work runs through sidekiq-cron, never cron in a container (§14.1).
class SweepQualityBreachesJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    Store.find_each do |store|
      breached = SweepQualityBreaches.call(store)

      # Only the stores where something actually changed — a newly breached
      # drink's marker (§9.4) has to reach the KDS, and everyone else's board
      # would otherwise repaint every 30s for nothing.
      KitchenBroadcast.call(store) if breached.any?
    end
  end
end

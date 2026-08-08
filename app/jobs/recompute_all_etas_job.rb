# §7.2's idle tick: "every 30s (catches drift from slow drinks in progress)".
#
# Nothing else fires while a barista is quietly making a 95-second drink, so
# without this the board's countdown freezes between transitions — and a drink
# running over its estimate never corrects until it finishes.
#
# Recurring work runs through sidekiq-cron, never cron in a container (§14.1).
class RecomputeAllEtasJob < ApplicationJob
  queue_as :default

  # Only stores with something to project. A closed shop does not need its
  # empty board recomputed twice a minute for the rest of the night.
  # @return [void]
  def perform
    Store.where(id: stores_with_open_work).find_each { |store| RecomputeEta.call(store) }
  end

  private

  def stores_with_open_work
    Order.open.joins(:order_items)
         .where(order_items: { status: %w[queued in_progress] })
         .distinct
         .select(:store_id)
  end
end

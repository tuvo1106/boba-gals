# Pushes each open order to the customer watching it (§9.2).
#
# One stream per pickup code rather than one per store: a customer's screen must
# not receive, and so must not be trusted to filter out, anybody else's order.
#
# Throttled on the same 1/sec leading-edge-with-trailing-flush window as the
# board (`ThrottledBroadcast`), and for the same reason. This is fanout squared
# — every drink transition changes the projected ETA of *every* open order, so a
# burst of twenty transitions in a store with forty open orders is eight hundred
# publishes if nothing damps it.
#
# Reads `EtaCache` rather than projecting (§7.2). The projection is measured at
# 175ms at 436 queued drinks (ADR-0012) and belongs in the background job that
# owns it, not on a broadcast path that runs once a second.
class OrderBroadcast
  extend ThrottledBroadcast

  # Matches `BoardBroadcast::WINDOW`: the two are the same event seen from two
  # sides of the counter, and a customer's screen disagreeing with the board
  # above it for a second is the one artefact worth avoiding here.
  WINDOW = 1.second

  PENDING_TTL = 10.seconds

  # Store-scoped because `pickup_code` is unique per store per day (§13.1), not
  # globally — two shops will hand out `A1B2` on the same afternoon (§16).
  #
  # @param order [Order]
  # @return [String]
  def self.stream_name(order)
    "order:#{order.store_id}:#{order.pickup_code}"
  end

  def self.throttle_name = "order"
  def self.window = WINDOW
  def self.pending_ttl = PENDING_TTL
  def self.flush_job = OrderFlushJob

  # Live orders only — `Order.live`, not `Order.open`.
  #
  # `open` means "ever placed": nothing in the application reaches a terminal
  # status (ADR-0017), so it grows by one row per order sold and never shrinks.
  # This was the only caller that iterated it directly, and it was the only
  # thing that grew with it. Measured on the compose stack:
  #
  #   open orders      27      527     2027
  #   publish        13ms    108ms    371ms
  #
  # against `ProjectEta` and `BoardView`, both flat across the same range —
  # they filter on *item* status, which is bounded by actual work.
  def self.publish(store)
    estimates = EtaCache.fetch(store)

    store.orders.live.includes(:order_items).find_each do |order|
      ActionCable.server.broadcast(
        stream_name(order),
        OrderView.call(order, eta_seconds: estimates.fetch(order.id, 0))
      )
    end
  end

  private_class_method :throttle_name, :window, :pending_ttl, :flush_job, :publish
end

# One customer watching their own order (§9.2).
#
# Authorized by the `pickup_code` alone, which is the design's deliberate choice
# (§13.1): the code is a low-value capability token, unique per store per day,
# and the REST endpoint it mirrors is throttled at 60/min per IP (§13.2).
#
# Rack::Attack cannot see individual `subscribe` attempts on an already-open
# connection (issue #39), so this channel enforces the same per-IP budget itself
# via `ThrottleOrderLookups`.
#
# The important property is what a subscriber *cannot* reach. The stream is per
# code, so a customer receives their own order and no one else's — unlike the
# board, which is public precisely because it carries only what is already being
# read aloud across the shop.
class OrderChannel < ApplicationCable::Channel
  def subscribed
    return reject if ThrottleOrderLookups.exceeded?(remote_ip)

    order = find_order

    if order.nil?
      ThrottleOrderLookups.record_failure(remote_ip)
      return reject
    end

    stream_from OrderBroadcast.stream_name(order)

    # Whole snapshot on subscribe (§9.2). A customer who reloads mid-wait sees
    # their order from the first frame rather than a blank screen until the next
    # drink happens to finish — which in a quiet store is minutes.
    transmit(OrderView.call(order, eta_seconds: eta_for(order)))
  end

  private

  def remote_ip
    connection.remote_ip
  end

  # v1 serves a single store and resolves it server-side, matching
  # `Api::V1::BaseController#current_store` — the same seam multi-store routing
  # will land on (§16).
  def find_order
    store = Store.first
    return nil if store.nil?

    store.orders.for_pickup_code(params[:pickup_code], on: store.business_date).first
  end

  def eta_for(order)
    EtaCache.fetch(order.store).fetch(order.id, 0)
  end
end

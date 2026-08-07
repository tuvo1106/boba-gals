# Live kitchen queue for the KDS (§9.2).
#
# The station token is verified here, not only at REST (§13.3). A REST-only
# check leaves the websocket as an unauthenticated read of the whole store's
# queue, and wrong-store tokens must be rejected at subscription time.
class KitchenChannel < ApplicationCable::Channel
  def subscribed
    claims = KdsToken.verify(params[:token])
    return reject if claims.nil?

    # A valid token for a different store is still a rejection. Store scoping is
    # what keeps the design's multi-store answer a routing problem (§16).
    return reject unless claims.store_id == params[:store_id].to_i

    store = Store.find_by(id: claims.store_id)
    return reject if store.nil?

    stream_from KitchenBroadcast.stream_name(store)

    # Send the current state immediately. Payloads are whole snapshots (§9.2),
    # so a client never has to reconstruct state from a stream of deltas it
    # joined halfway through.
    transmit(KitchenQueue.call(store))
  end
end

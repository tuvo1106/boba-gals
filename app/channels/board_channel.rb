# Live customer board (§9.2).
#
# Deliberately unauthenticated. `GET /board` is public in the surface map
# (§13.1) and this carries exactly the same data — first names and pickup codes,
# which are already being read aloud across the shop. The privacy rule that
# matters here is what the payload *omits*: `customer_phone` never reaches any
# broadcast (§13.5), which BoardView enforces by construction.
class BoardChannel < ApplicationCable::Channel
  def subscribed
    store = Store.find_by(id: params[:store_id])
    return reject if store.nil?

    stream_from BoardBroadcast.stream_name(store)

    # Whole snapshot on subscribe (§9.2), so a screen that reconnects mid-shift
    # renders correctly from the first frame instead of waiting for the next
    # drink to finish.
    transmit(BoardView.call(store))
  end
end

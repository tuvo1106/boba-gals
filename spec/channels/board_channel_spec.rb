require "rails_helper"

RSpec.describe BoardChannel, type: :channel do
  let(:store) { create(:store, :with_stations) }

  # Deliberately unauthenticated: `GET /board` is public in the surface map
  # (§13.1) and this carries the same data. The privacy that matters is what the
  # payload omits, which BoardView holds the line on.
  it "subscribes without any token" do
    subscribe(store_id: store.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(BoardBroadcast.stream_name(store))
  end

  it "rejects a subscription to a store that does not exist" do
    subscribe(store_id: -1)

    expect(subscription).to be_rejected
  end

  it "rejects a subscription with no store at all" do
    subscribe

    expect(subscription).to be_rejected
  end

  # Payloads are whole snapshots (§9.2), so a board that reconnects mid-shift
  # renders correctly from the first frame rather than waiting for the next
  # drink to finish.
  it "immediately transmits the current board" do
    order = create(:order, store: store, customer_first_name: "Sarah")
    create(:order_item, order: order, menu_item: create(:menu_item, store: store))

    subscribe(store_id: store.id)

    expect(transmissions.last).to include("type" => "board_update")
    expect(transmissions.last["making"].first).to include("first_name" => "Sarah")
  end

  it "never transmits customer_phone (§13.5)" do
    order = create(:order, :web, store: store, customer_phone: "+15555550123")
    create(:order_item, order: order, menu_item: create(:menu_item, store: store))

    subscribe(store_id: store.id)

    expect(transmissions.last.to_json).not_to include("5555550123")
  end
end

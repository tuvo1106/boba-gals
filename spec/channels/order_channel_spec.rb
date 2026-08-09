require "rails_helper"

RSpec.describe OrderChannel, type: :channel do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store) }

  def place(**attrs)
    order = create(:order, store: store, **attrs)
    create(:order_item, order: order, menu_item: menu_item, label: "Taro Slush")
    order
  end

  it "subscribes with the pickup code alone (§13.1)" do
    order = place

    subscribe(pickup_code: order.pickup_code)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(OrderBroadcast.stream_name(order))
  end

  # The code is printed on a receipt and read back by people; a customer typing
  # it in lower case is not a different order.
  it "accepts the code in any case" do
    order = place(pickup_code: "A1B2")

    subscribe(pickup_code: "a1b2")

    expect(subscription).to be_confirmed
  end

  it "rejects a code that matches nothing" do
    place

    subscribe(pickup_code: "ZZZZ")

    expect(subscription).to be_rejected
  end

  it "rejects a subscription with no code at all" do
    subscribe

    expect(subscription).to be_rejected
  end

  # Codes are unique per store per *day* (§13.1) and get reused. A channel that
  # ignored the date would be a second, weaker lock on the same room — the REST
  # endpoint it mirrors scopes to today.
  it "rejects yesterday's code" do
    order = place(placed_at: 1.day.ago)

    subscribe(pickup_code: order.pickup_code)

    expect(subscription).to be_rejected
  end

  # Whole snapshots (§9.2), so a customer who reloads mid-wait sees their order
  # from the first frame rather than a blank screen until the next drink
  # happens to finish — which in a quiet store is minutes.
  it "immediately transmits the order" do
    order = place(status: "in_progress")

    subscribe(pickup_code: order.pickup_code)

    expect(transmissions.last).to include(
      "type" => "order_update",
      "pickup_code" => order.pickup_code,
      "status" => "in_progress"
    )
    expect(transmissions.last["items"].first).to include("label" => "Taro Slush")
  end

  it "transmits the projected wait with it" do
    order = place
    EtaCache.write(store, { order.id => 275 })

    subscribe(pickup_code: order.pickup_code)

    expect(transmissions.last).to include("eta_seconds" => 275)
  end

  it "never transmits customer_phone (§13.5)" do
    order = place(source: "web", customer_phone: "+15555550123")

    subscribe(pickup_code: order.pickup_code)

    expect(transmissions.last.to_json).not_to include("5555550123")
  end

  # The whole point of a per-code stream: subscribing to your own order must not
  # put you on anyone else's.
  it "does not stream anybody else's order" do
    mine = place
    theirs = place(customer_first_name: "Cleo")

    subscribe(pickup_code: mine.pickup_code)

    expect(subscription).not_to have_stream_from(OrderBroadcast.stream_name(theirs))
  end
end

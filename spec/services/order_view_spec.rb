require "rails_helper"

RSpec.describe OrderView do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store) }

  it "reports the order's status and its projected wait" do
    order = create(:order, store: store, status: "in_progress")
    create(:order_item, order: order, menu_item: menu_item)

    payload = described_class.call(order, eta_seconds: 240)

    expect(payload).to include(
      type: "order_update",
      pickup_code: order.pickup_code,
      status: "in_progress",
      eta_seconds: 240
    )
  end

  # §6 interleaves one order's drinks with everyone else's, so an order in the
  # middle of being made is genuinely part-done. A single order-level status
  # would sit at "in progress" for eight minutes and tell the customer nothing.
  it "reports each drink separately, in the order they were placed" do
    order = create(:order, store: store)
    create(:order_item, order: order, menu_item: menu_item, label: "Taro Slush", sequence: 2)
    create(:order_item, order: order, menu_item: menu_item, label: "Thai Tea", sequence: 1, status: "finished")

    payload = described_class.call(order)

    expect(payload[:items].map { |i| i[:label] }).to eq([ "Thai Tea", "Taro Slush" ])
    expect(payload[:items].map { |i| i[:status] }).to eq([ "finished", "queued" ])
  end

  it "quotes zero when nothing has been projected for this order yet" do
    order = create(:order, store: store)

    expect(described_class.call(order)).to include(eta_seconds: 0)
  end

  # §13.5: `customer_phone` never appears in any broadcast payload. This is the
  # one view reached by a bare capability token (§13.1), so it is the one that
  # would leak it furthest.
  it "never carries customer_phone (§13.5)" do
    order = create(:order, :web, store: store, customer_phone: "+15555550123")
    create(:order_item, order: order, menu_item: menu_item)

    expect(described_class.call(order).to_json).not_to include("5555550123")
  end

  # A remade drink already has a replacement row (§5.2). Leaving the failed one
  # in shows three lines for a two-drink order and explains neither.
  it "omits a drink that failed, because its replacement is already listed" do
    order = create(:order, store: store)
    failed = create(:order_item, order: order, menu_item: menu_item, label: "Thai Tea",
                                 status: "failed", sequence: 1)
    create(:order_item, order: order, menu_item: menu_item, label: "Taro Slush", sequence: 2)
    create(:order_item, order: order, menu_item: menu_item, label: "Thai Tea", sequence: 3,
                        remake_of: failed, remake_reason: "spill")

    payload = described_class.call(order)

    expect(payload[:items].map { |i| i[:label] }).to eq([ "Taro Slush", "Thai Tea" ])
    expect(payload[:items].map { |i| i[:id] }).not_to include(failed.id)
  end

  it "omits a cancelled drink for the same reason" do
    order = create(:order, store: store)
    create(:order_item, order: order, menu_item: menu_item, status: "cancelled", sequence: 1)
    create(:order_item, order: order, menu_item: menu_item, label: "Taro Slush", sequence: 2)

    expect(described_class.call(order)[:items].map { |i| i[:label] }).to eq([ "Taro Slush" ])
  end

  # A customer's own screen has no business knowing who else is in the queue.
  it "carries nothing about anybody else's order" do
    order = create(:order, store: store, customer_first_name: "Sam")
    create(:order_item, order: order, menu_item: menu_item, label: "Thai Tea")
    other = create(:order, store: store, customer_first_name: "Cleo")
    create(:order_item, order: other, menu_item: menu_item, label: "Brown Sugar Pearl")

    payload = described_class.call(order).to_json

    expect(payload).not_to include("Cleo")
    expect(payload).not_to include("Brown Sugar Pearl")
    expect(payload).not_to include(other.pickup_code)
  end
end

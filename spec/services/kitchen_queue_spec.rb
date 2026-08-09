require "rails_helper"

RSpec.describe KitchenQueue do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store) }

  def card_for(payload, item)
    (payload[:in_progress] + payload[:next_up]).find { |c| c[:id] == item.id }
  end

  # §9.4: "position within its order (`2 of 5`)". Both halves of that phrase are
  # about the order the customer placed, not about rows in a table.
  describe "the position a card renders" do
    it "numbers a drink by where it sits in its order" do
      order = create(:order, store: store)
      first = create(:order_item, order: order, menu_item: menu_item, sequence: 1)
      second = create(:order_item, order: order, menu_item: menu_item, sequence: 2)

      payload = described_class.call(store)

      expect(card_for(payload, first)).to include(position: 1, order_size: 2)
      expect(card_for(payload, second)).to include(position: 2, order_size: 2)
    end

    # The bug this spec exists for. A remake is appended with a `sequence` after
    # every existing drink (§5.2), so rendering the raw column showed a
    # two-drink order with one spill as "2 of 3" and "3 of 3" — an order that
    # appears to grow because a drink was dropped. Observed on the cluster, at
    # the same moment the customer's own screen said "0 of 2 made".
    it "still counts two drinks after one of them is spilled and remade" do
      order = create(:order, store: store)
      spilled = create(:order_item, order: order, menu_item: menu_item, sequence: 1, status: "in_progress")
      survivor = create(:order_item, order: order, menu_item: menu_item, sequence: 2)

      FailDrink.new.call(spilled, reason: "spill")
      remake = order.order_items.find_by(remake_of: spilled)

      payload = described_class.call(store)

      expect(card_for(payload, survivor)).to include(position: 1, order_size: 2)
      expect(card_for(payload, remake)).to include(position: 2, order_size: 2)
    end

    # The failed drink is gone from the board, not shown as "remaking" — the
    # replacement stands in its place (§5.2).
    it "does not render the drink that failed" do
      order = create(:order, store: store)
      spilled = create(:order_item, order: order, menu_item: menu_item, sequence: 1, status: "in_progress")

      FailDrink.new.call(spilled, reason: "spill")

      expect(card_for(described_class.call(store), spilled)).to be_nil
    end

    # The same numbers the customer is reading off their own screen. These two
    # views were written from the same rule and drifted apart once; asserting
    # them against each other is what stops that happening quietly again.
    it "agrees with what the customer's screen says the order is" do
      order = create(:order, store: store)
      spilled = create(:order_item, order: order, menu_item: menu_item, sequence: 1, status: "in_progress")
      create(:order_item, order: order, menu_item: menu_item, sequence: 2)

      FailDrink.new.call(spilled, reason: "spill")

      kds_size = described_class.call(store)[:next_up].map { |c| c[:order_size] }.uniq
      customer_size = OrderView.call(order.reload)[:items].size

      expect(kds_size).to eq([ customer_size ])
    end
  end

  it "marks a remake so the card can carry its persistent marker (§9.4)" do
    order = create(:order, store: store)
    spilled = create(:order_item, order: order, menu_item: menu_item, sequence: 1, status: "in_progress")

    FailDrink.new.call(spilled, reason: "spill")
    remake = order.order_items.find_by(remake_of: spilled)

    expect(card_for(described_class.call(store), remake)).to include(remake: true)
  end

  # §13.5, and the KDS is a broadcast payload like any other.
  it "never carries customer_phone" do
    order = create(:order, :web, store: store, customer_phone: "+15555550123")
    create(:order_item, order: order, menu_item: menu_item, sequence: 1)

    expect(described_class.call(store).to_s).not_to include("5555550123")
  end
end

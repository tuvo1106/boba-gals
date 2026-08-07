require "rails_helper"

RSpec.describe BoardView do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }

  def order_with_drinks(count = 1, **attrs)
    order = create(:order, store: store, **attrs)
    count.times { |i| create(:order_item, order: order, menu_item: menu_item, sequence: i + 1) }
    order
  end

  describe "privacy (§3, §13.5)" do
    # The locked decision is first name plus code. This is the spec that fails
    # if anyone ever adds a field "just for the KDS" to a payload that is
    # rendered on a screen the whole shop can see.
    it "exposes only first name, code, items, and timing" do
      order_with_drinks(1, customer_first_name: "Sarah")

      row = described_class.call(store)[:making].first

      expect(row.keys).to contain_exactly(:first_name, :pickup_code, :items, :eta_seconds)
    end

    it "never exposes customer_phone anywhere in the payload" do
      order = create(:order, :web, store: store, customer_phone: "+15555550123")
      create(:order_item, order: order, menu_item: menu_item)

      expect(described_class.call(store).to_json).not_to include("5555550123")
    end
  end

  describe "making" do
    it "includes placed, in-progress, and partially ready orders" do
      order_with_drinks(1, status: "placed")
      order_with_drinks(1, status: "in_progress")
      order_with_drinks(1, status: "partially_ready")

      expect(described_class.call(store)[:making].size).to eq(3)
    end

    # A partially ready order looks done to the customer if it lands in Ready,
    # which sends them to the counter for a drink still in a shaker.
    it "keeps a partially ready order out of the ready column" do
      order_with_drinks(2, status: "partially_ready")

      expect(described_class.call(store)[:ready]).to be_empty
    end

    it "lists the drinks in the order they were added" do
      order = create(:order, store: store)
      create(:order_item, order: order, menu_item: menu_item, label: "Thai Tea", sequence: 2)
      create(:order_item, order: order, menu_item: menu_item, label: "Taro Slush", sequence: 1)

      expect(described_class.call(store)[:making].first[:items]).to eq([ "Taro Slush", "Thai Tea" ])
    end

    it "sorts soonest first" do
      first = order_with_drinks(1)
      second = order_with_drinks(3)

      codes = described_class.call(store)[:making].map { |row| row[:pickup_code] }

      expect(codes).to eq([ first.pickup_code, second.pickup_code ])
    end

    it "excludes orders from other stores" do
      other = create(:store, :with_stations)
      create(:order_item, order: create(:order, store: other),
                          menu_item: create(:menu_item, store: other))

      expect(described_class.call(store)[:making]).to be_empty
    end

    it "excludes terminal orders" do
      order_with_drinks(1, status: "cancelled")
      order_with_drinks(1, status: "abandoned")

      expect(described_class.call(store)[:making]).to be_empty
    end
  end

  describe "ready" do
    it "reports how long an order has been waiting" do
      create(:order, store: store, status: "ready", ready_at: 45.seconds.ago)

      expect(described_class.call(store)[:ready].first[:ready_since_seconds]).to be_within(2).of(45)
    end

    it "puts the most recently ready order at the top" do
      older = create(:order, store: store, status: "ready", ready_at: 3.minutes.ago)
      newer = create(:order, store: store, status: "ready", ready_at: 10.seconds.ago)

      codes = described_class.call(store)[:ready].map { |row| row[:pickup_code] }

      expect(codes).to eq([ newer.pickup_code, older.pickup_code ])
    end

    # ADR-0005: nothing sets picked_up_at, so this timer is the only thing
    # keeping the column from growing for the length of a shift.
    describe "retiring rows" do
      it "keeps an order that went ready inside the window" do
        create(:order, store: store, status: "ready",
                       ready_at: (described_class::READY_BOARD_TTL - 30.seconds).ago)

        expect(described_class.call(store)[:ready].size).to eq(1)
      end

      it "retires an order that went ready before the window" do
        create(:order, store: store, status: "ready",
                       ready_at: (described_class::READY_BOARD_TTL + 30.seconds).ago)

        expect(described_class.call(store)[:ready]).to be_empty
      end

      # Retiring a row is a display decision, not a state change — the order is
      # still open until the 45-minute abandoned sweep (§5.1).
      it "does not change the order's status" do
        order = create(:order, store: store, status: "ready",
                               ready_at: (described_class::READY_BOARD_TTL + 30.seconds).ago)

        described_class.call(store)

        expect(order.reload.status).to eq("ready")
      end
    end

    # §9.5: "Items persist for 90 seconds after picked_up_at so a customer
    # walking up doesn't see their name vanish." Unreachable live (ADR-0005),
    # but the read side is correct for whenever a pickup signal does arrive.
    describe "the 90-second pickup persistence" do
      it "keeps an order collected within the window" do
        create(:order, store: store, status: "picked_up",
                       ready_at: 2.minutes.ago, picked_up_at: 30.seconds.ago)

        row = described_class.call(store)[:ready].first

        expect(row[:picked_up_seconds_ago]).to be_within(2).of(30)
      end

      it "drops an order collected before the window" do
        create(:order, store: store, status: "picked_up",
                       ready_at: 5.minutes.ago, picked_up_at: 2.minutes.ago)

        expect(described_class.call(store)[:ready]).to be_empty
      end

      # A collected order stays visible even once its ready_at is older than the
      # board TTL — the 90-second courtesy is measured from collection.
      it "outranks the board TTL for a recently collected order" do
        create(:order, store: store, status: "picked_up",
                       ready_at: 20.minutes.ago, picked_up_at: 10.seconds.ago)

        expect(described_class.call(store)[:ready].size).to eq(1)
      end
    end
  end
end

require "rails_helper"

RSpec.describe NaiveEta do
  # Safety factor 1.0 keeps the arithmetic in these examples legible. The factor
  # itself gets its own example rather than being smeared across every other
  # expectation.
  let(:store) { create(:store, :with_stations, scheduler_config: { "eta_safety_factor" => 1.0 }) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }

  def queue(order, count, prep: 60, queued_at: Time.current)
    count.times do |i|
      create(:order_item, order: order, menu_item: menu_item, prep_seconds: prep,
                          queued_at: queued_at, sequence: i + 1)
    end
  end

  describe ".for_open_orders" do
    # The reason this class exists rather than a flat store-wide average: a
    # board where the next order and the tenth read the same number is worse
    # than no board (ADR-0004).
    it "gives later orders a longer estimate than earlier ones" do
      first = create(:order, store: store)
      second = create(:order, store: store)
      queue(first, 3, queued_at: 2.minutes.ago)
      queue(second, 1, queued_at: 1.minute.ago)

      estimates = described_class.for_open_orders(store)

      expect(estimates[first.id]).to be < estimates[second.id]
    end

    it "divides cumulative work by active stations" do
      order = create(:order, store: store)
      queue(order, 3) # 180 seconds of work, 3 stations

      expect(described_class.for_open_orders(store)[order.id]).to eq(60)
    end

    # Runtime capacity is `stations WHERE active`, never the station_count seed
    # column (§4.1) — deactivating a station has to move the number.
    it "uses active stations rather than the seeded station_count" do
      store.stations.limit(2).update_all(active: false)
      order = create(:order, store: store)
      queue(order, 3)

      expect(described_class.for_open_orders(store)[order.id]).to eq(180)
    end

    it "still answers when every station is deactivated" do
      store.stations.update_all(active: false)
      order = create(:order, store: store)
      queue(order, 1)

      expect(described_class.for_open_orders(store)[order.id]).to eq(60)
    end

    # §7.1: order ETA is multiplied by eta_safety_factor. Quoting the raw
    # estimate means being late half the time.
    it "applies the store's eta_safety_factor" do
      store.update!(scheduler_config: { "eta_safety_factor" => 1.5 })
      order = create(:order, store: store)
      queue(order, 3)

      expect(described_class.for_open_orders(store)[order.id]).to eq(90)
    end

    it "ignores drinks that are already finished" do
      order = create(:order, store: store)
      queue(order, 1)
      create(:order_item, :finished, order: order, menu_item: menu_item, prep_seconds: 600)

      expect(described_class.for_open_orders(store)[order.id]).to eq(20)
    end

    it "ignores other stores" do
      other = create(:store, :with_stations)
      queue(create(:order, store: other), 10)
      order = create(:order, store: store)
      queue(order, 3)

      expect(described_class.for_open_orders(store)[order.id]).to eq(60)
    end

    it "returns an empty hash when nothing is queued" do
      expect(described_class.for_open_orders(store)).to eq({})
    end

    describe "order-ahead" do
      # A catering order promised for 2pm must not add eight minutes to
      # everyone standing at the counter at noon (ADR-0004, §6.2).
      it "excludes work that is not due yet from everyone else's estimate" do
        asap = create(:order, store: store)
        queue(asap, 3, queued_at: 1.minute.ago)
        later = create(:order, store: store, promised_at: 2.hours.from_now)
        queue(later, 15, queued_at: Time.current)

        expect(described_class.for_open_orders(store)[asap.id]).to eq(60)
      end

      it "estimates a deferred order from its promise, not its queue position" do
        order = create(:order, store: store, promised_at: 30.minutes.from_now)
        queue(order, 1)

        expect(described_class.for_open_orders(store)[order.id]).to be_within(2).of(1800)
      end

      # Once its backward-scheduled start arrives it is ordinary work again, and
      # counts toward everything behind it.
      it "counts a promised order that is due now" do
        due = create(:order, store: store, promised_at: 1.minute.from_now)
        queue(due, 3, queued_at: 1.minute.ago)
        asap = create(:order, store: store)
        queue(asap, 3)

        expect(described_class.for_open_orders(store)[asap.id]).to eq(120)
      end
    end
  end

  describe ".for_store" do
    it "estimates the wait for an order that has not been placed yet" do
      order = create(:order, store: store)
      queue(order, 3)

      expect(described_class.for_store(store)).to eq(60)
    end

    it "is zero for an empty store" do
      expect(described_class.for_store(store)).to eq(0)
    end
  end
end

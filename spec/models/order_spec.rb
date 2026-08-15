require "rails_helper"

RSpec.describe Order do
  subject(:order) { build(:order) }

  it { is_expected.to belong_to(:store) }
  it { is_expected.to have_many(:order_items).dependent(:destroy) }
  it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
  it { is_expected.to validate_inclusion_of(:source).in_array(described_class::SOURCES) }

  describe "the §5.1 state machine" do
    it "covers every documented status" do
      expect(described_class::STATUSES).to eq(
        %w[draft placed in_progress partially_ready ready picked_up abandoned cancelled]
      )
    end

    # `abandoned` is swept 45 minutes after ready_at and is terminal like
    # picked_up — excluded from the open-orders index and from the board (§5.1).
    it "treats picked_up, abandoned, and cancelled as terminal" do
      expect(described_class::TERMINAL_STATUSES).to contain_exactly("picked_up", "abandoned", "cancelled")
    end
  end

  describe ".open" do
    it "excludes terminal orders" do
      store = create(:store)
      live = create(:order, store: store, status: "in_progress")
      create(:order, store: store, status: "picked_up")
      create(:order, store: store, status: "abandoned")

      expect(store.orders.open).to contain_exactly(live)
    end
  end

  describe "customer_phone (§13.5)" do
    it "is rejected on kiosk orders, which have nobody to text" do
      order = build(:order, source: "kiosk", customer_phone: "+15555550123")

      expect(order).not_to be_valid
      expect(order.errors[:customer_phone]).to be_present
    end

    it "is allowed on web orders, for the single ready SMS (§9.7)" do
      expect(build(:order, :web)).to be_valid
    end

    it "is still optional — most web customers just wait" do
      expect(build(:order, :web, customer_phone: nil)).to be_valid
      expect(build(:order, :web, customer_phone: "")).to be_valid
    end

    # A number that cannot receive a text is worse than no number: the order is
    # placed, the drinks are made, and the ready SMS (§9.7) goes nowhere with
    # nothing to say it did.
    it "rejects something that could never receive a text" do
      [ "555", "not a phone", "12345", "+", "5551234567890123456" ].each do |bad|
        order = build(:order, :web, customer_phone: bad)

        expect(order).not_to be_valid, "expected #{bad.inspect} to be rejected"
        expect(order.errors[:customer_phone]).to be_present
      end
    end

    # "(555) 555-0123" is a phone number. Refusing it because of the brackets
    # teaches people to distrust the field, so the formatting is stripped and
    # the digits are what get counted and stored.
    it "accepts the formatting people actually type, and stores what would be dialled" do
      order = create(:order, :web, customer_phone: "(555) 555-0123")

      expect(order.customer_phone).to eq("5555550123")
    end

    it "keeps a country code when one is given" do
      expect(create(:order, :web, customer_phone: "+1 555 555 0123").customer_phone)
        .to eq("+15555550123")
    end

    # Deliberate: this shop has no country on record, and turning a bare
    # 10-digit number into `+1…` would send the ready text to a stranger in the
    # wrong country. Normalising to E.164 belongs with the Twilio integration,
    # which will know where the store is (§16).
    it "does not invent a country code" do
      expect(create(:order, :web, customer_phone: "5555550123").customer_phone)
        .not_to start_with("+")
    end
  end

  describe "#size_class (§10.4)" do
    def order_with(drink_count)
      order = create(:order)
      drink_count.times { |i| create(:order_item, order: order, sequence: i + 1) }
      order
    end

    it "classes 1-2 drinks as \"1-2\"" do
      expect(order_with(1).size_class).to eq("1-2")
      expect(order_with(2).size_class).to eq("1-2")
    end

    it "classes 3-6 drinks as \"3-6\"" do
      expect(order_with(3).size_class).to eq("3-6")
      expect(order_with(6).size_class).to eq("3-6")
    end

    it "classes 7 or more drinks as \"7+\", uncapped" do
      expect(order_with(7).size_class).to eq("7+")
      expect(order_with(20).size_class).to eq("7+")
    end

    it "is nil for an order with no countable drinks yet" do
      expect(create(:order).size_class).to be_nil
    end
  end

  describe "#promised?" do
    it "is false for ASAP orders" do
      expect(build(:order, promised_at: nil)).not_to be_promised
    end

    it "is true for order-ahead, which the scheduler holds back (§6.2)" do
      expect(build(:order, :promised)).to be_promised
    end
  end

  # ADR-0036. The bug this pins was reachable every day at 17:00 local for a
  # store in America/Los_Angeles, which is peak service: the UTC day rolled
  # over, `PickupCode.taken?` considered a live order's code free, it was
  # reissued, and the first customer's status page rendered the second
  # customer's order. The pickup code is the capability token (§13.1), so that
  # is a cross-customer read.
  describe "the business day is the shop's, not UTC's (§13.1, ADR-0036)" do
    let(:store) { create(:store, timezone: "America/Los_Angeles") }

    # 16:58 PDT == 23:58 UTC; 17:05 PDT == 00:05 the next UTC day.
    let(:before_utc_rollover) { Time.utc(2026, 8, 14, 23, 58) }
    let(:after_utc_rollover) { Time.utc(2026, 8, 15, 0, 5) }

    it "keeps an order findable by its code across the UTC midnight mid-service" do
      order = create(:order, store: store, pickup_code: "K7QF", placed_at: before_utc_rollover)

      travel_to(after_utc_rollover) do
        found = store.orders.for_pickup_code("K7QF", on: store.business_date)

        expect(found).to contain_exactly(order)
      end
    end

    it "still considers that code taken, so it cannot be reissued to someone else" do
      create(:order, store: store, pickup_code: "K7QF", placed_at: before_utc_rollover)

      travel_to(after_utc_rollover) do
        expect(PickupCode.taken?(store: store, code: "K7QF", on: store.business_date)).to be(true)
      end
    end

    # The other half: a code genuinely from yesterday *is* free again, which is
    # what makes a 4-character alphabet workable at all (§13.1).
    it "frees a code once the shop's own day has actually turned over" do
      create(:order, store: store, pickup_code: "K7QF", placed_at: before_utc_rollover)

      # 09:00 PDT the following morning — a new shop day by any reading.
      travel_to(Time.utc(2026, 8, 15, 16, 0)) do
        expect(PickupCode.taken?(store: store, code: "K7QF", on: store.business_date)).to be(false)
      end
    end

    it "stamps business_date from the store's zone, not the server's" do
      order = create(:order, store: store, placed_at: before_utc_rollover)

      expect(order.business_date).to eq(Date.new(2026, 8, 14)),
        "23:58 UTC is still the 14th in Los Angeles"
    end
  end
end

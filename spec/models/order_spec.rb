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

  describe "#promised?" do
    it "is false for ASAP orders" do
      expect(build(:order, promised_at: nil)).not_to be_promised
    end

    it "is true for order-ahead, which the scheduler holds back (§6.2)" do
      expect(build(:order, :promised)).to be_promised
    end
  end
end

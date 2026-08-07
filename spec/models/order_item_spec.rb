require "rails_helper"

RSpec.describe OrderItem do
  subject(:item) { build(:order_item) }

  it { is_expected.to belong_to(:order) }
  it { is_expected.to belong_to(:menu_item) }
  it { is_expected.to belong_to(:station).optional }
  it { is_expected.to belong_to(:barista).optional }
  it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

  describe "the §5.2 state machine" do
    it "covers every documented status" do
      expect(described_class::STATUSES).to eq(%w[queued in_progress finished failed cancelled])
    end
  end

  describe "remakes" do
    # A failed drink is never un-finished — the remake is a new row pointing
    # back at the original. That keeps prep-time statistics honest and makes
    # remakes visible in reporting (§5.2).
    it "is a new row linked to the drink it replaces" do
      order = create(:order)
      original = create(:order_item, order: order)
      remake = create(:order_item, order: order, remake_of: original, remake_reason: "spill")

      expect(remake).to be_remake
      expect(original).not_to be_remake
      expect(original.remakes).to contain_exactly(remake)
    end
  end

  describe ".dispatchable" do
    # Build step 1 is FIFO only: strict queued_at ordering. The scheduler (§6)
    # changes which queued item is picked, never how items got queued.
    it "returns queued items oldest first" do
      order = create(:order)
      newer = create(:order_item, order: order, queued_at: 1.minute.ago)
      older = create(:order_item, order: order, queued_at: 5.minutes.ago)
      create(:order_item, :finished, order: order)

      expect(described_class.dispatchable).to eq([ older, newer ])
    end
  end

  describe ".active" do
    it "covers queued and in-progress work, which is what a station holds" do
      order = create(:order)
      queued = create(:order_item, order: order)
      working = create(:order_item, :in_progress, order: order)
      create(:order_item, :finished, order: order)

      expect(described_class.active).to contain_exactly(queued, working)
    end
  end
end

require "rails_helper"

RSpec.describe OrderSerializer do
  let(:store) { create(:store) }

  describe "customer_phone (§13.5)" do
    # The board privacy rule (§3) is first name plus code only, and §13.5 extends
    # that to every serializer except the admin order view and to every
    # ActionCable payload. Asserting on the whole serialized structure — rather
    # than just checking one key is absent — is what makes this survive someone
    # adding a nested association later.
    it "appears nowhere in the output, at any depth" do
      order = create(:order, :web, store: store, customer_phone: "+15555550123")
      create(:order_item, order: order)

      serialized = described_class.call(order).to_json

      expect(serialized).not_to include("5555550123")
      expect(serialized).not_to include("customer_phone")
    end
  end

  it "exposes first name and pickup code, which the board is allowed to show (§3)" do
    order = create(:order, store: store, customer_first_name: "Sarah")

    expect(described_class.call(order)).to include(
      customer_first_name: "Sarah",
      pickup_code: order.pickup_code
    )
  end

  it "returns items in their display sequence (§4.1)" do
    order = create(:order, store: store)
    create(:order_item, order: order, sequence: 2, label: "Taro Slush")
    create(:order_item, order: order, sequence: 1, label: "Thai Tea")

    expect(described_class.call(order)[:items].map { |i| i[:label] }).to eq([ "Thai Tea", "Taro Slush" ])
  end

  it "marks remakes so the KDS can render its persistent marker (§9.4)" do
    order = create(:order, store: store)
    original = create(:order_item, order: order)
    create(:order_item, order: order, remake_of: original, remake_reason: "spill")

    expect(described_class.call(order)[:items].map { |i| i[:remake] }).to contain_exactly(false, true)
  end
end

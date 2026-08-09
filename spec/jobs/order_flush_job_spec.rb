require "rails_helper"

RSpec.describe OrderFlushJob do
  let(:store) { create(:store, :with_stations) }

  it "flushes the store's pending order broadcasts" do
    order = create(:order, store: store)
    create(:order_item, order: order, menu_item: create(:menu_item, store: store))
    OrderBroadcast.call(store)

    expect { described_class.perform_now(store.id) }
      .to have_broadcasted_to(OrderBroadcast.stream_name(order))
  end

  # A store deleted between scheduling and running is not an error worth
  # retrying — the flush has nothing left to say.
  it "does nothing for a store that has gone away" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end
end

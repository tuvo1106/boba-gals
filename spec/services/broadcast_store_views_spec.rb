require "rails_helper"

# The kitchen and the board are two views of the same drinks. Broadcasting them
# from separate call sites is how one ends up updated and the other stale, which
# reads to staff as "the board is broken" long after the cause is forgettable.
#
# These examples are about the *wiring*, not the payloads — every transition in
# the system has to reach both screens.
RSpec.describe BroadcastStoreViews do
  let(:store) { create(:store, :with_stations) }
  let(:station) { store.stations.first }
  let(:barista) { create(:barista, store: store) }
  let(:menu_item) { create(:menu_item, store: store) }

  def kitchen = KitchenBroadcast.stream_name(store)
  def board = BoardBroadcast.stream_name(store)

  it "reaches both screens" do
    expect { described_class.call(store) }
      .to have_broadcasted_to(kitchen)
      .and have_broadcasted_to(board)
  end

  # Each transition is set up with factories rather than by calling the previous
  # service, so the example under test is the first thing to touch the throttle
  # window and its broadcast is a real leading-edge one. Driving the setup
  # through ClaimNextDrink and FinishDrink instead would leave the window closed
  # and the assertion would be about the flush, not the transition.
  describe "the transitions that have to reach the board" do
    let(:order) { create(:order, store: store) }

    it "broadcasts when a drink is claimed" do
      create(:order_item, order: order, menu_item: menu_item)

      expect { ClaimNextDrink.new.call(station: station, barista: barista) }
        .to have_broadcasted_to(board)
    end

    it "broadcasts when a drink is finished" do
      item = create(:order_item, :in_progress, order: order, menu_item: menu_item)

      expect { FinishDrink.new.call(item) }.to have_broadcasted_to(board)
    end

    it "broadcasts when an action is undone" do
      item = create(:order_item, :finished, order: order, menu_item: menu_item)

      expect { UndoLastAction.new.call(item) }.to have_broadcasted_to(board)
    end
  end

  # A placed order that does not appear until someone refreshes is the one
  # transition a customer watches for directly.
  it "broadcasts when an order is placed" do
    result = nil

    expect {
      result = CreateOrder.new(store: store).call(
        source: "kiosk", items: [ { menu_item_id: menu_item.id } ], customer_first_name: "Sarah"
      )
    }.to have_broadcasted_to(board)

    expect(result).to be_success
  end
end

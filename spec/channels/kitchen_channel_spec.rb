require "rails_helper"

RSpec.describe KitchenChannel, type: :channel do
  let(:store) { create(:store) }
  let(:station) { create(:station, store: store) }
  let(:barista) { create(:barista, store: store) }
  let(:token) { KdsToken.issue(barista: barista, station: station) }

  # §13.3 is explicit that wrong-store tokens are rejected at channel
  # subscription, not just at REST. A REST-only check would leave the websocket
  # as an unauthenticated read of the whole store's queue.
  describe "authorization" do
    it "subscribes with a valid token for the matching store" do
      subscribe(token: token, store_id: store.id)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("kitchen:#{store.id}")
    end

    it "rejects a missing token" do
      subscribe(store_id: store.id)

      expect(subscription).to be_rejected
    end

    it "rejects a tampered token" do
      subscribe(token: "#{token}x", store_id: store.id)

      expect(subscription).to be_rejected
    end

    it "rejects a valid token aimed at a different store" do
      other = create(:store)

      subscribe(token: token, store_id: other.id)

      expect(subscription).to be_rejected
    end

    it "rejects an expired token" do
      # Issued before travelling, not inside the block: `token` is lazy, and
      # evaluating it under a moved clock would mint a fresh 12-hour token that
      # is trivially still valid.
      issued = token

      travel_to((KdsToken::TTL + 1.minute).from_now) do
        subscribe(token: issued, store_id: store.id)
      end

      expect(subscription).to be_rejected
    end
  end

  describe "on subscribe" do
    # Payloads are whole snapshots, not deltas (§9.2), so a client never has to
    # reconstruct state from a stream it joined halfway through.
    it "immediately transmits the current queue" do
      create(:order_item, order: create(:order, store: store),
                          menu_item: create(:menu_item, store: store))

      subscribe(token: token, store_id: store.id)

      expect(transmissions.last).to include("type" => "queue_update", "depth" => 1)
    end
  end
end

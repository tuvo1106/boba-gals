require "rails_helper"

RSpec.describe "Api::V1::Kds", type: :request do
  let!(:store) { create(:store) }
  let!(:station) { create(:station, store: store, name: "Bar 1") }
  let!(:barista) { create(:barista, store: store, name: "Sam", pin: "1234") }
  let(:token) { KdsToken.issue(barista: barista, station: station) }
  let(:auth) { { "Authorization" => "Bearer #{token}" } }

  def queue_drink(order: create(:order, store: store), **attrs)
    create(:order_item, order: order, menu_item: create(:menu_item, store: store), **attrs)
  end

  describe "POST /api/v1/kds/session" do
    it "exchanges a PIN and station for a token" do
      post "/api/v1/kds/session", params: { barista_pin: "1234", station_id: station.id }, as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["token"]).to be_present
      expect(body["barista"]).to include("name" => "Sam")
      expect(KdsToken.verify(body["token"])).to have_attributes(barista_id: barista.id, store_id: store.id)
    end

    # KitchenChannel refuses a subscription whose store_id does not match the
    # token (§13.3), so a client that is not told the store id can only guess —
    # and guessing the station id happens to work for station 1 of store 1 and
    # for nothing else. Every other station sits at "connecting" forever, with
    # no error, because a refused subscription is silent.
    it "tells the client which store it is in, so it can subscribe" do
      post "/api/v1/kds/session", params: { barista_pin: "1234", station_id: station.id }, as: :json

      body = response.parsed_body
      expect(body["store"]).to include("id" => store.id)
      expect(body["store"]["id"]).not_to eq(body["station"]["id"]),
        "this example is worthless unless the two ids actually differ"
    end

    it "rejects a wrong PIN" do
      post "/api/v1/kds/session", params: { barista_pin: "9999", station_id: station.id }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    # Identical message either way, so the response can't be used to enumerate
    # which station ids exist.
    it "gives the same answer for an unknown station as for a wrong PIN" do
      post "/api/v1/kds/session", params: { barista_pin: "1234", station_id: -1 }, as: :json
      unknown_station = response.parsed_body

      post "/api/v1/kds/session", params: { barista_pin: "0000", station_id: station.id }, as: :json

      expect(unknown_station).to eq(response.parsed_body)
    end

    it "never returns the PIN digest" do
      post "/api/v1/kds/session", params: { barista_pin: "1234", station_id: station.id }, as: :json

      expect(response.body).not_to include("pin_digest")
    end
  end

  describe "authentication (§13.3)" do
    it "rejects a request with no token" do
      get "/api/v1/kds/queue"

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a tampered token" do
      get "/api/v1/kds/queue", headers: { "Authorization" => "Bearer #{token}x" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects an expired token" do
      get "/api/v1/kds/queue", headers: auth
      expect(response).to have_http_status(:ok)

      travel_to((KdsToken::TTL + 1.minute).from_now) do
        get "/api/v1/kds/queue", headers: auth
      end

      expect(response).to have_http_status(:unauthorized)
    end

    it "cannot reach another store's drinks" do
      other_item = create(:order_item, order: create(:order, store: create(:store)))

      post "/api/v1/kds/items/#{other_item.id}/finish", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/kds/queue" do
    it "returns in-progress work, the next three drinks, and the depth (§9.4)" do
      5.times { queue_drink }
      queue_drink(status: "in_progress", started_at: Time.current, station: station)

      get "/api/v1/kds/queue", headers: auth

      body = response.parsed_body
      expect(body["in_progress"].size).to eq(1)
      expect(body["next_up"].size).to eq(KitchenQueue::NEXT_UP)
      expect(body["depth"]).to eq(5)
      expect(body["oldest_waiting_seconds"]).to be >= 0
    end

    it "shows each drink's position within its order, so a barista sees 2 of 5" do
      order = create(:order, store: store)
      2.times { |i| queue_drink(order: order, sequence: i + 1) }

      get "/api/v1/kds/queue", headers: auth

      expect(response.parsed_body["next_up"].first).to include("position" => 1, "order_size" => 2)
    end

    it "never exposes customer_phone (§13.5)" do
      queue_drink(order: create(:order, :web, store: store, customer_phone: "+15555550123"))

      get "/api/v1/kds/queue", headers: auth

      expect(response.body).not_to include("5555550123")
    end
  end

  describe "POST /api/v1/kds/items/start" do
    # No item id: the barista taps "start next" and the server decides. That is
    # what lets step 5 swap FIFO for the scheduler with no client change.
    it "claims the oldest queued drink" do
      older = queue_drink(queued_at: 5.minutes.ago)
      queue_drink(queued_at: 1.minute.ago)

      post "/api/v1/kds/items/start", headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["id"]).to eq(older.id)
      expect(older.reload).to have_attributes(status: "in_progress", station_id: station.id)
    end

    it "404s when nothing is queued" do
      post "/api/v1/kds/items/start", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/kds/items/:id/finish" do
    it "finishes the drink and readies its order" do
      item = queue_drink(status: "in_progress", started_at: 1.minute.ago, station: station)

      post "/api/v1/kds/items/#{item.id}/finish", headers: auth

      expect(response).to have_http_status(:ok)
      expect(item.reload.status).to eq("finished")
      expect(item.order.reload.status).to eq("ready")
    end

    it "422s a drink that was never started" do
      item = queue_drink

      post "/api/v1/kds/items/#{item.id}/finish", headers: auth

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/kds/items/:id/fail" do
    it "queues a replacement and returns it, not the drink that went wrong" do
      item = queue_drink(status: "in_progress", started_at: 1.minute.ago, station: station)

      post "/api/v1/kds/items/#{item.id}/fail", params: { reason: "spill" }, headers: auth, as: :json

      expect(response).to have_http_status(:ok)
      expect(item.reload.status).to eq("failed")
      # The remake is what the barista now has to make; returning the dead row
      # would put it back on screen.
      expect(response.parsed_body).to include("status" => "queued", "remake" => true)
      expect(response.parsed_body["id"]).not_to eq(item.id)
    end

    it "rejects a reason that is not one of §9.4's three" do
      item = queue_drink(status: "in_progress", started_at: 1.minute.ago, station: station)

      post "/api/v1/kds/items/#{item.id}/fail", params: { reason: "because" }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(item.reload.status).to eq("in_progress")
    end

    it "cannot fail another store's drink" do
      other = create(:order_item, order: create(:order, store: create(:store)),
                     status: "in_progress", started_at: 1.minute.ago)

      post "/api/v1/kds/items/#{other.id}/fail", params: { reason: "spill" }, headers: auth, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/kds/items/:id/undo" do
    it "reverses the last transition inside the window (§9.4)" do
      item = queue_drink(status: "in_progress", started_at: 1.minute.ago, station: station)
      post "/api/v1/kds/items/#{item.id}/finish", headers: auth

      post "/api/v1/kds/items/#{item.id}/undo", headers: auth

      expect(response).to have_http_status(:ok)
      expect(item.reload.status).to eq("in_progress")
    end
  end
end

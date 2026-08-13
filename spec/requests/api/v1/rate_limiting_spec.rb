require "rails_helper"

RSpec.describe "Rate limiting (§13.2)", type: :request do
  let!(:store) { create(:store, :with_stations) }
  let!(:menu_item) { create(:menu_item, :thai_tea, store: store) }
  let!(:station) { create(:station, store: store) }

  def order_payload
    { order: { source: "kiosk", customer_first_name: "Sam", items: [ { menu_item_id: menu_item.id } ] } }
  end

  describe "orders/ip" do
    it "throttles the 11th POST /api/v1/orders within a minute" do
      10.times { post "/api/v1/orders", params: order_payload, as: :json }
      expect(response).not_to have_http_status(:too_many_requests)

      post "/api/v1/orders", params: order_payload, as: :json

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to eq("rate limit exceeded")
      expect(response.headers["Retry-After"]).to be_present
    end

    it "does not count a GET, since the throttle is scoped to POST" do
      10.times { post "/api/v1/orders", params: order_payload, as: :json }

      get "/api/v1/orders/ZZZZ"

      expect(response).to have_http_status(:not_found)
    end

    # §13.2: a busy Saturday from the store's own kiosk would otherwise trip
    # this throttle. The safelist is checked per-request, not at boot, so
    # setting KIOSK_IPS mid-example is enough.
    it "does not throttle an IP on the KIOSK_IPS safelist" do
      ENV["KIOSK_IPS"] = "9.9.9.9"

      11.times { post "/api/v1/orders", params: order_payload, as: :json, env: { "REMOTE_ADDR" => "9.9.9.9" } }

      expect(response).not_to have_http_status(:too_many_requests)
    ensure
      ENV.delete("KIOSK_IPS")
    end
  end

  describe "status/ip" do
    it "throttles the 61st GET /api/v1/orders/:pickup_code within a minute" do
      order = create(:order, store: store, pickup_code: "K7QF")

      60.times { get "/api/v1/orders/#{order.pickup_code}" }
      expect(response).not_to have_http_status(:too_many_requests)

      get "/api/v1/orders/#{order.pickup_code}"

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "kds_pin/ip" do
    it "throttles the 11th POST /api/v1/kds/session within a minute" do
      10.times { post "/api/v1/kds/session", params: { barista_pin: "0000", station_id: station.id }, as: :json }
      expect(response).not_to have_http_status(:too_many_requests)

      post "/api/v1/kds/session", params: { barista_pin: "0000", station_id: station.id }, as: :json

      expect(response).to have_http_status(:too_many_requests)
    end
  end
end

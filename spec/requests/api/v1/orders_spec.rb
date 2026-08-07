require "rails_helper"

RSpec.describe "Api::V1::Orders", type: :request do
  let!(:store) { create(:store, :with_stations) }
  let!(:menu_item) { create(:menu_item, :thai_tea, store: store) }

  def payload(items:, **rest)
    { order: { source: "kiosk", customer_first_name: "Sam", items: items, **rest } }
  end

  describe "POST /api/v1/orders" do
    it "creates the order and returns its pickup code and quote" do
      post "/api/v1/orders", params: payload(items: [ { menu_item_id: menu_item.id } ]), as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["pickup_code"]).to match(/\A[A-Z0-9]{4}\z/)
      expect(body["status"]).to eq("placed")
      expect(body["quoted_wait_seconds"]).to be_a(Integer)
      expect(body["items"].sole["label"]).to eq("Thai Tea")
    end

    it "issues a pickup code from the unambiguous alphabet (§13.1)" do
      post "/api/v1/orders", params: payload(items: [ { menu_item_id: menu_item.id } ]), as: :json

      expect(response.parsed_body["pickup_code"].chars).to all(satisfy { |c| PickupCode::ALPHABET.include?(c) })
    end

    it "returns 422 with messages when the order is invalid" do
      post "/api/v1/orders", params: payload(items: []), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to be_present
    end

    it "never echoes customer_phone back (§13.5)" do
      post "/api/v1/orders",
           params: payload(items: [ { menu_item_id: menu_item.id } ], source: "web",
                           customer_phone: "+15555550123"),
           as: :json

      expect(response.body).not_to include("5555550123")
      expect(response.parsed_body).not_to have_key("customer_phone")
    end
  end

  describe "GET /api/v1/orders/:pickup_code" do
    # The code is the capability token (§13.1) — no session, no id.
    it "returns the order for a valid code" do
      order = create(:order, store: store, pickup_code: "K7QF")

      get "/api/v1/orders/K7QF"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["pickup_code"]).to eq(order.pickup_code)
    end

    it "accepts a lowercase code, since customers retype it" do
      create(:order, store: store, pickup_code: "K7QF")

      get "/api/v1/orders/k7qf"

      expect(response).to have_http_status(:ok)
    end

    it "404s an unknown code" do
      get "/api/v1/orders/ZZZZ"

      expect(response).to have_http_status(:not_found)
    end

    # Codes are unique per store *per day* (idx_pickup_code_daily), so scoping
    # the lookup to today is what stops yesterday's code reading today's order.
    it "does not expose an order placed on an earlier day" do
      create(:order, store: store, pickup_code: "K7QF", placed_at: 2.days.ago)

      get "/api/v1/orders/K7QF"

      expect(response).to have_http_status(:not_found)
    end

    it "never exposes customer_phone (§13.5)" do
      create(:order, :web, store: store, pickup_code: "K7QF", customer_phone: "+15555550123")

      get "/api/v1/orders/K7QF"

      expect(response.body).not_to include("5555550123")
    end
  end
end

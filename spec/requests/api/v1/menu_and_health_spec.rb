require "rails_helper"

RSpec.describe "Api::V1 menu and health", type: :request do
  let!(:store) { create(:store) }

  describe "GET /api/v1/menu" do
    it "returns available items with their option groups" do
      create(:menu_item, :with_options, store: store, name: "Taro Milk Tea")

      get "/api/v1/menu"

      expect(response).to have_http_status(:ok)
      item = response.parsed_body["items"].sole
      expect(item["name"]).to eq("Taro Milk Tea")
      expect(item["option_groups"].map { |g| g["name"] }).to contain_exactly("Sweetness", "Toppings")
    end

    it "omits unavailable items" do
      create(:menu_item, store: store, name: "Sold Out", available: false)
      create(:menu_item, store: store, name: "In Stock")

      get "/api/v1/menu"

      expect(response.parsed_body["items"].map { |i| i["name"] }).to eq([ "In Stock" ])
    end

    it "exposes min_select and max_select so the client can pick its control" do
      create(:menu_item, :with_options, store: store)

      get "/api/v1/menu"

      sweetness = response.parsed_body["items"].sole["option_groups"].find { |g| g["name"] == "Sweetness" }
      expect(sweetness).to include("min_select" => 1, "max_select" => 1)
    end
  end

  describe "GET /api/v1/health" do
    # Business-level, not liveness. The kiosk polls this every 10s and shows the
    # paused state after two failures (§9.3); the kubelet polls /up (§14.3).
    it "reports the store as accepting orders" do
      get "/api/v1/health"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("accepting_orders" => true)
    end

    it "reports refusal without failing the request, so k8s does not restart the pod" do
      store.update!(accepting_orders: false)

      get "/api/v1/health"

      expect(response).to have_http_status(:ok),
        "an owner flipping accepting_orders off must not look like an unhealthy pod (§14.3)"
      expect(response.parsed_body).to include("accepting_orders" => false)
    end
  end
end

require "rails_helper"

RSpec.describe "Rate limiting (§13.2)", type: :request do
  let!(:store) { create(:store, :with_stations) }
  let!(:menu_item) { create(:menu_item, :thai_tea, store: store) }
  let!(:station) { create(:station, store: store) }

  # Every example here counts requests up to a limit inside one throttle period,
  # and Rack::Attack's periods are **fixed windows aligned to the epoch**, not
  # sliding ones. The cache key is
  # `"rack::attack:#{epoch_time / period}:#{name}:#{discriminator}"`
  # (`Cache#key_and_expiry`), so the counter resets on wall-clock minute
  # boundaries. A run that straddles one starts counting again partway through:
  # six requests land in one window, the remaining five in the next, and the
  # request that should be the 11th is only the 5th of its window and comes back
  # 201 instead of 429.
  #
  # That is a genuine flake, not a slow machine — it depends on *when* the
  # example starts, not how long it takes.
  #
  # **Freezing the clock alone is not enough, which is the subtle part.** The
  # window index in the key is frozen, but the Redis counter still carries a
  # *real-time* TTL, computed once from the frozen second:
  #
  #     expires_in = period - (epoch_time % period) + 1
  #
  # and applied with `EXPIRE … NX`, so later increments never extend it. Freeze
  # at second 59 and the counter is given **two real seconds** to live while the
  # logical window never advances — an example slower than that loses its count
  # mid-run and fails exactly the same way.
  #
  # So freeze to the **start** of a window, where `expires_in` takes its maximum
  # of 61s. Verified both directions: frozen at second 59 with a 2.5s delay the
  # eleventh request returns 201; frozen at the window start the same delay
  # still returns 429.
  around { |example| travel_to(Time.at(Time.current.to_i / 60 * 60)) { example.run } }

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

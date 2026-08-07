require "rails_helper"

RSpec.describe "GET /api/v1/board" do
  let!(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }
  let(:body) { JSON.parse(response.body) }

  # Public (§13.1) — the board hangs on a wall and its data is already being
  # read aloud across the shop.
  it "needs no authentication" do
    get "/api/v1/board"

    expect(response).to have_http_status(:ok)
    expect(body["type"]).to eq("board_update")
  end

  it "returns empty columns for a quiet store" do
    get "/api/v1/board"

    expect(body["making"]).to be_empty
    expect(body["ready"]).to be_empty
  end

  it "shows a placed order under making with a wait in seconds" do
    order = create(:order, store: store, customer_first_name: "Sarah")
    create(:order_item, order: order, menu_item: menu_item, label: "Thai Tea, 50%")

    get "/api/v1/board"

    expect(body["making"]).to contain_exactly(
      "first_name" => "Sarah",
      "pickup_code" => order.pickup_code,
      "items" => [ "Thai Tea, 50%" ],
      "eta_seconds" => be_positive
    )
  end

  it "shows a finished order under ready" do
    order = create(:order, store: store, customer_first_name: "Ali",
                           status: "ready", ready_at: 20.seconds.ago)

    get "/api/v1/board"

    expect(body["making"]).to be_empty
    expect(body["ready"].first).to include("first_name" => "Ali", "pickup_code" => order.pickup_code)
  end

  # The locked privacy rule (§3, §13.5). This is a public endpoint, so it is the
  # one most worth holding.
  it "never returns customer_phone" do
    order = create(:order, :web, store: store, customer_phone: "+15555550123")
    create(:order_item, order: order, menu_item: menu_item)

    get "/api/v1/board"

    expect(response.body).not_to include("5555550123")
    expect(response.body).not_to include("customer_phone")
  end
end

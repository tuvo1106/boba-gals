require "rails_helper"

RSpec.describe "POST /api/v1/admin/staffing_curves (§10.5 #3)" do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: "correct-horse-battery-staple") }

  def body = JSON.parse(response.body)

  def sign_in
    post "/api/v1/admin/session", params: { email: admin.email, password: "correct-horse-battery-staple" }, as: :json
  end

  def curve(**params)
    post "/api/v1/admin/staffing_curves", params: { demand_multiplier: 1.6, **params }, as: :json
  end

  it "refuses without an admin session" do
    curve(seed: 1)

    expect(response).to have_http_status(:unauthorized)
  end

  context "signed in" do
    before { sign_in }

    it "returns one entry per open hour, ascending" do
      curve(seed: 7)

      expect(response).to have_http_status(:ok)
      expect(body["hours"].map { |h| h["hour"] }).to eq((10..20).to_a)
    end

    it "carries what each hour needs" do
      curve(seed: 7)

      expect(body["hours"]).to all(include("stations", "achieved", "p90", "orders", "p90_meaningful"))
    end

    # "Every run must display its seed" (§10.6) — a schedule nobody can
    # reproduce is not one an operator can act on.
    it "reports everything needed to reproduce the schedule" do
      curve(seed: 7, seeds: 2, target_seconds: 300)

      expect(body).to include(
        "seed" => 7, "seeds" => 2, "demand_multiplier" => 1.6, "target_seconds" => 300.0
      )
    end

    it "is reproducible from the seed" do
      curve(seed: 7)
      first = body

      curve(seed: 7)

      expect(body).to eq(first)
    end

    # The number actually used, not the number asked for.
    it "reports the clamped day count rather than the requested one" do
      stub_const("Simulator::StaffingCurve::MAX_SEEDS", 2)

      curve(seed: 7, seeds: 10_000)

      expect(body["seeds"]).to eq(2)
      expect(body["hours"]).to all(include("orders"))
    end

    it "defaults to one day and the default target" do
      curve(seed: 7)

      expect(body["seeds"]).to eq(1)
      expect(body["target_seconds"]).to eq(Simulator::StaffingCurve::DEFAULT_TARGET_SECONDS)
    end
  end
end

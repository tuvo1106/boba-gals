require "rails_helper"

RSpec.describe "POST /api/v1/admin/breaking_points (§10.5 #4)" do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: "correct-horse-battery-staple") }

  def body = JSON.parse(response.body)

  def sign_in
    post "/api/v1/admin/session", params: { email: admin.email, password: "correct-horse-battery-staple" }, as: :json
  end

  def sweep(**params)
    post "/api/v1/admin/breaking_points", params: params, as: :json
  end

  it "refuses without an admin session" do
    sweep(seed: 1)

    expect(response).to have_http_status(:unauthorized)
  end

  # This spec is about routing, auth, and response shape — `Simulator::BreakingPoint`'s
  # own spec already covers the real, unstubbed range. Narrowed here for the
  # same reason `StaffingCurve`'s request spec narrows its station range.
  context "signed in" do
    before do
      sign_in
      stub_const("Simulator::BreakingPoint::POINTS", [ 0.5, 1.0 ])
    end

    it "returns the swept points, ascending" do
      sweep(seed: 7)

      expect(response).to have_http_status(:ok)
      expect(body["points"].map { |p| p["demand_multiplier"] }).to eq([ 0.5, 1.0 ])
    end

    it "carries the overall wait percentiles capacity is judged on" do
      sweep(seed: 7)

      expect(body["points"]).to all(include("metrics" => include("wait_seconds")))
    end

    # "Every run must display its seed" (§10.6).
    it "reports everything needed to reproduce the chart" do
      sweep(seed: 7, stations: 4, seeds: 2)

      expect(body).to include("seed" => 7, "seeds" => 2, "stations" => 4, "target_seconds" => 900.0)
    end

    it "is reproducible from the seed" do
      sweep(seed: 7)
      first = body

      sweep(seed: 7)

      expect(body).to eq(first)
    end

    it "reports the clamped day count rather than the requested one" do
      stub_const("Simulator::BreakingPoint::MAX_SEEDS", 2)

      sweep(seed: 7, seeds: 10_000)

      expect(body["seeds"]).to eq(2)
      expect(body["points"].first["metrics"]["orders"]).to be_positive
    end

    it "defaults to one day and 900 seconds" do
      sweep(seed: 7)

      expect(body["seeds"]).to eq(1)
      expect(body["target_seconds"]).to eq(900.0)
    end

    it "reports nil capacity when an unreachable target crosses nothing" do
      sweep(seed: 7, target_seconds: 1_000_000)

      expect(body["capacity"]).to be_nil
    end
  end
end

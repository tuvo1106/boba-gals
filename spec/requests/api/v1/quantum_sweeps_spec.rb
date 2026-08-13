require "rails_helper"

RSpec.describe "POST /api/v1/admin/quantum_sweeps (§10.5)" do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: "correct-horse-battery-staple") }

  def body = JSON.parse(response.body)

  def sign_in
    post "/api/v1/admin/session", params: { email: admin.email, password: "correct-horse-battery-staple" }, as: :json
  end

  def sweep(**params)
    post "/api/v1/admin/quantum_sweeps", params: { demand_multiplier: 1.6, **params }, as: :json
  end

  it "refuses without an admin session" do
    sweep(seed: 1)

    expect(response).to have_http_status(:unauthorized)
  end

  # This spec is about routing, auth, and response shape — `QuantumSweep`'s
  # own spec already covers the real ten-point range end to end (as `:slow`,
  # docs/testing.md). Narrowed here for the same reason.
  context "signed in" do
    before do
      sign_in
      stub_const("Simulator::QuantumSweep::POINTS", [ 30, 400 ])
    end

    it "returns the swept points, ascending" do
      sweep(seed: 7)

      expect(response).to have_http_status(:ok)
      expect(body["points"].map { |p| p["quantum"] }).to eq(Simulator::QuantumSweep::POINTS)
    end

    it "carries the size-class breakdown every point is judged on" do
      sweep(seed: 7)

      expect(body["points"]).to all(include("metrics" => include("by_size_class")))
    end

    # "Every run must display its seed" (§10.6) — a sweep chart nobody can
    # reproduce is worth less than nothing.
    it "reports everything needed to reproduce the chart" do
      sweep(seed: 7, stations: 4, seeds: 2)

      expect(body).to include(
        "seed" => 7, "seeds" => 2, "stations" => 4, "demand_multiplier" => 1.6
      )
    end

    it "is reproducible from the seed" do
      sweep(seed: 7)
      first = body

      sweep(seed: 7)

      expect(body).to eq(first)
    end

    # The number actually used, not the number asked for.
    it "reports the clamped day count rather than the requested one" do
      stub_const("Simulator::QuantumSweep::MAX_SEEDS", 2)

      sweep(seed: 7, seeds: 10_000)

      expect(body["seeds"]).to eq(2)
      expect(body["points"].first["metrics"]["orders"]).to be_positive
    end

    it "defaults to one day" do
      sweep(seed: 7)

      expect(body["seeds"]).to eq(1)
    end
  end
end

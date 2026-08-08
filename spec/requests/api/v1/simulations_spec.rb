require "rails_helper"

RSpec.describe "POST /api/v1/admin/simulations (§9.1, §10.1)" do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: "correct-horse-battery-staple") }
  # A method, not a `let`. Memoisation would make every example that posts twice
  # compare the first response to itself — which silently turned the
  # reproducibility test below into a tautology.
  def body = JSON.parse(response.body)

  def sign_in
    post "/api/v1/admin/session", params: { email: admin.email, password: "correct-horse-battery-staple" }, as: :json
  end

  def simulate(**params)
    post "/api/v1/admin/simulations", params: params, as: :json
  end

  # A run is unbounded compute, and the knobs are the same ones that tune the
  # live store (§13.4).
  it "refuses without an admin session" do
    simulate(seed: 1)

    expect(response).to have_http_status(:unauthorized)
  end

  context "signed in" do
    before { sign_in }

    it "returns metrics and the seed that produced them" do
      simulate(seed: 7)

      expect(response).to have_http_status(:ok)
      expect(body["seed"]).to eq(7)
      expect(body["metrics"]["wait_seconds"].keys).to eq(%w[p50 p90 p99])
    end

    # "Every run must display its seed" (§10.6) — and the same seed must give
    # the same run, or a surprising result cannot be replayed.
    it "is reproducible from the seed" do
      simulate(seed: 7)
      first = body

      simulate(seed: 7)

      expect(body).to eq(first)
    end

    it "returns a different run for a different seed" do
      simulate(seed: 7)
      first = body["metrics"]

      simulate(seed: 8)

      expect(body["metrics"]).not_to eq(first)
    end

    describe "the timeline the ribbon renders (§10.6)" do
      it "places every drink on a station, in time order" do
        simulate(seed: 7)
        timeline = body["timeline"]

        expect(timeline).to be_any
        expect(timeline.map { |d| d["started_at"] }).to eq(timeline.map { |d| d["started_at"] }.sort)
        expect(timeline).to all(include("station", "order_id", "finished_at"))
      end

      # The ribbon colours capsules by order and the fairness claim is that a
      # large order's drinks are visibly interleaved with small ones — which
      # only holds if a window actually contains several orders at once.
      it "interleaves orders within a window rather than draining one at a time" do
        # A window during the lunch peak (§10.3's profile puts 48 orders/hour in
        # the third hour). At opening the shop takes 12 an hour and one station
        # handles everything, so an early window shows nothing worth looking at.
        simulate(seed: 7, window_from: 7200, window_seconds: 900)

        stations = body["timeline"].group_by { |d| d["station"] }
        expect(stations.keys.size).to be > 1
        expect(body["timeline"].map { |d| d["order_id"] }.uniq.size).to be > 3
      end

      # A full day is thousands of capsules; no screen renders that legibly.
      it "returns only the requested window" do
        simulate(seed: 7, window_from: 600, window_seconds: 300)

        starts = body["timeline"].map { |d| d["started_at"] }

        expect(body["window"]).to eq("from" => 600.0, "to" => 900.0)
        expect(starts).to all(be_between(600, 900))
      end
    end

    it "honours the scheduler config it is given" do
      simulate(seed: 7, scheduler_config: { policy: "fifo" })
      fifo = body["metrics"]["by_size_class"]["1-2"]["p90"]

      simulate(seed: 7, scheduler_config: { policy: "drr" })

      expect(body["metrics"]["by_size_class"]["1-2"]["p90"]).not_to eq(fifo)
    end

    # Reuses the admin allowlist, so a simulation cannot be asked to run a
    # policy the store could never be set to (§14.6).
    it "ignores keys that are not scheduler settings" do
      simulate(seed: 7, scheduler_config: { policy: "drr", twilio_auth_token: "sk-live-oops" })

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("twilio")
    end

    it "accepts the staffing and demand knobs the dashboard exposes" do
      simulate(seed: 7, stations: 5, demand_multiplier: 2.0, large_order_rate: 0.12)

      expect(body["stations"]).to eq(5)
      expect(body["metrics"]["orders"]).to be_positive
    end
  end
end

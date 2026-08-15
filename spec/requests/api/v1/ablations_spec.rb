require "rails_helper"

RSpec.describe "POST /api/v1/admin/ablations (§10.5, §10.6)" do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: "correct-horse-battery-staple") }

  # A method, not a `let` — memoisation would compare a response to itself.
  def body = JSON.parse(response.body)

  def sign_in
    post "/api/v1/admin/session", params: { email: admin.email, password: "correct-horse-battery-staple" }, as: :json
  end

  def ablate(**params)
    post "/api/v1/admin/ablations", params: { demand_multiplier: 1.6, **params }, as: :json
  end

  # Four runs per seed, and the knobs are the ones that tune the live store
  # (§13.4).
  it "refuses without an admin session" do
    ablate(seed: 1)

    expect(response).to have_http_status(:unauthorized)
  end

  context "signed in" do
    before { sign_in }

    it "returns §10.5's ladder and §6.3's comparison arms, in order" do
      ablate(seed: 7)

      expect(response).to have_http_status(:ok)
      expect(body["arms"].map { |a| a["id"] })
        .to eq(%w[fifo rr drr drr_aging drr_aging_cohesion sjf])
    end

    # The chart sets the bound apart from the ladder and cannot do that without
    # this field (§6.3).
    it "says which arms are rungs and which is only a bound" do
      ablate(seed: 7)

      expect(body["arms"].to_h { |a| [ a["id"], a["kind"] ] })
        .to include("fifo" => "control", "drr" => "rung", "sjf" => "bound")
    end

    # Everything below checks presence and plumbing, never a specific arm's
    # identity, so two arms (real configs, just fewer of them) prove the same
    # thing for a third of the cost.
    context "with a narrowed arm list" do
      before { stub_const("Simulator::Ablation::ARMS", Simulator::Ablation::ARMS.first(2)) }

      # Both comparison arms are judged on drink cost rather than order size —
      # SJF's whole damage lands there (§6.1). A payload without it leaves the
      # chart's second axis with nothing to draw.
      it "carries the drink-cost split every arm is judged on" do
        ablate(seed: 7)

        expect(body["arms"]).to all(include("metrics" => include("wait_by_drink_cost")))
      end

      it "labels each arm for someone who has not read §6" do
        ablate(seed: 7)

        expect(body["arms"].map { |a| a["label"] }).to all(be_present)
        expect(body["arms"].map { |a| a["blurb"] }).to all(be_present)
      end

      # "Every run must display its seed" (§10.6), and a bar chart comparing
      # schedulers is worth less than nothing if nobody can re-run it.
      it "reports everything needed to reproduce the chart" do
        ablate(seed: 7, stations: 4, seeds: 2, quantum: 90)

        expect(body).to include(
          "seed" => 7, "seeds" => 2, "stations" => 4, "quantum" => 90,
          "demand_multiplier" => 1.6
        )
      end

      it "is reproducible from the seed" do
        ablate(seed: 7)
        first = body

        ablate(seed: 7)

        expect(body).to eq(first)
      end

      # The number actually used, not the number asked for — a response claiming
      # 10,000 days when it ran 25 is a lie the chart would repeat.
      # Stubbed rather than run at the real ceiling: what matters is that the
      # response reports the number used, not that 25 is the number. Running it
      # for real meant simulating 150 days to check one integer.
      it "reports the clamped day count rather than the requested one" do
        stub_const("Simulator::Ablation::MAX_SEEDS", 2)

        ablate(seed: 7, seeds: 10_000)

        expect(body["seeds"]).to eq(2)
        expect(body["arms"].first["metrics"]["orders"]).to be_positive
      end

      it "defaults to one day, as §10.5 specifies" do
        ablate(seed: 7)

        expect(body["seeds"]).to eq(1)
      end
    end
  end

  # `params[:quantum].to_i` turns 0, -5 and the typo "sixty" all into zero, and
  # a zero quantum means the deficit never reaches any item's cost — the ring
  # spins until LIVELOCK_GUARD trips at 10,000 rounds and raises, so a mistyped
  # sweep came back a 500 rather than a result.
  describe "a quantum the scheduler cannot run (§6.6)" do
    before do
      sign_in
      stub_const("Simulator::Ablation::ARMS", Simulator::Ablation::ARMS.first(1))
    end

    it "clamps zero up into the runnable range rather than raising" do
      expect { ablate(seed: 7, quantum: 0) }.not_to raise_error

      expect(response).to have_http_status(:ok)
      expect(body["quantum"]).to eq(UpdateSchedulerConfig::SCHEMA.dig("quantum", :min))
    end

    it "clamps a non-numeric quantum the same way, rather than running at zero" do
      ablate(seed: 7, quantum: "sixty")

      expect(response).to have_http_status(:ok)
      expect(body["quantum"]).to eq(UpdateSchedulerConfig::SCHEMA.dig("quantum", :min))
    end

    it "clamps an absurdly large quantum down to the range the store allows" do
      ablate(seed: 7, quantum: 99_999)

      expect(body["quantum"]).to eq(UpdateSchedulerConfig::SCHEMA.dig("quantum", :max))
    end

    it "leaves a sane quantum untouched" do
      ablate(seed: 7, quantum: 90)

      expect(body["quantum"]).to eq(90)
    end
  end
end

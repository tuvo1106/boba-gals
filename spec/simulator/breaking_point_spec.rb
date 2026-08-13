require "rails_helper"

RSpec.describe Simulator::BreakingPoint do
  def sweep(**overrides)
    described_class.call(seed: 7, stations: 3, **overrides)
  end

  def point(result, demand_multiplier) = result[:points].find { |p| p[:demand_multiplier] == demand_multiplier }

  it "targets 15 minutes by default" do
    expect(described_class::TARGET_SECONDS).to eq(900)
  end

  it "caps the swept range at 3x demand, on cost — see the class comment" do
    expect(described_class::POINTS.last).to eq(3.0)
    expect(described_class::POINTS).to eq(described_class::POINTS.sort)
  end

  # The one example that runs the real, unstubbed range end to end (CLAUDE.md
  # "keep simulator specs lean"). Costed deliberately: at seed 7 and 3
  # stations, overall p90 crosses 900s between 1.5x and 1.75x, so one pooled
  # day settles it — this is not a borderline reading that would need extra
  # days to trust. Every example below narrows `POINTS` instead; none of them
  # care where in the range the answer lands.
  it "sweeps the real points, ascending, and reports the capacity it finds" do
    result = sweep

    expect(result[:points].map { |p| p[:demand_multiplier] }).to eq(described_class::POINTS)
    expect(point(result, 1.0)[:metrics]).to include(:wait_seconds, :orders)
    expect(result[:capacity]).to eq(1.75)
  end

  context "with a narrowed point range" do
    before { stub_const("#{described_class}::POINTS", [ 0.5, 1.0 ]) }

    # Unlike `Ablation`/`QuantumSweep`, points here are *not* expected to
    # share arrivals — demand_multiplier scales the arrival intensity itself
    # (§10.1), so a higher point sees more customers by construction.
    it "sees more customers at a higher demand multiplier" do
      result = sweep

      expect(point(result, 1.0)[:arrived]).to be > point(result, 0.5)[:arrived]
    end

    it "reports nil capacity when nothing in range crosses an unreachable target" do
      expect(sweep(target_seconds: 1_000_000)[:capacity]).to be_nil
    end

    it "reports the smallest point as capacity when every point crosses a trivial target" do
      expect(sweep(target_seconds: 0)[:capacity]).to eq(0.5)
    end

    it "is reproducible from the seed" do
      expect(sweep).to eq(sweep)
    end

    it "refuses to run more days than the ceiling" do
      stub_const("#{described_class}::MAX_SEEDS", 2)

      expect(sweep(seeds: 10_000)).to eq(sweep(seeds: 2))
    end

    it "treats a nonsense day count as one day" do
      expect(sweep(seeds: 0)).to eq(sweep(seeds: 1))
    end
  end

  it "keeps the ceiling at 25 days, mirroring Ablation::MAX_SEEDS" do
    expect(described_class::MAX_SEEDS).to eq(25)
  end
end

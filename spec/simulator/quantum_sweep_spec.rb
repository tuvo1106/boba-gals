require "rails_helper"

RSpec.describe Simulator::QuantumSweep do
  # Busy enough that a quantum change can show up. Below saturation every
  # quantum dispatches almost the same schedule, the same reason `Ablation`'s
  # spec runs at 1.6× rather than 1.0×.
  def sweep(**overrides)
    described_class.call(seed: 7, stations: 3, demand_multiplier: 1.6, **overrides)
  end

  def point(runs, quantum) = runs.find { |p| p[:quantum] == quantum }

  # Real POINTS, unstubbed — but cheap enough (1.4s at this file's demand) to
  # stay in the default tier rather than behind `:slow`. `spans...` needs no
  # simulation at all.
  it "sweeps §10.5's ten points, ascending" do
    expect(sweep.map { |p| p[:quantum] }).to eq(described_class::POINTS)
    expect(described_class::POINTS).to eq(described_class::POINTS.sort)
  end

  it "spans §10.5's stated range" do
    expect(described_class::POINTS.first).to eq(30)
    expect(described_class::POINTS.last).to eq(400)
  end

  # §10.5 #2's whole point: "plot small-order p90 and large-order p90
  # together. The crossover is your setting." Pooled over several days rather
  # than one, because a single day is noisy enough that the middle of the
  # sweep is not monotonic — the endpoints are where the trade is
  # unambiguous. The one example that runs the real ten-point range end to
  # end, so it is `:slow` (docs/testing.md) — 6s on its own, and the least
  # affordable of this file's examples to run on every push.
  it "trades small-order wait for large-order wait as the quantum grows", :slow do
    runs = sweep(seeds: 5)

    small_at = ->(q) { point(runs, q)[:metrics][:by_size_class]["1-2"][:p90] }
    large_at = ->(q) { point(runs, q)[:metrics][:by_size_class]["7+"][:p90] }

    expect(small_at.call(400)).to be > small_at.call(30)
    expect(large_at.call(400)).to be < large_at.call(30)
  end

  it "keeps the ceiling at 25 days, mirroring Ablation::MAX_SEEDS" do
    expect(described_class::MAX_SEEDS).to eq(25)
  end

  # Everything below only cares about the mechanism (clamping, reproducing,
  # a shared-arrivals property that holds at any point count) rather than the
  # real ten-point range, so two points prove the same thing for a fraction
  # of the cost — benchmarked at 0.28s against 1.4s for the full sweep, and
  # 1.9s against 8.55s at the demand the shared-customers check also runs at.
  context "with a narrowed point range" do
    before { stub_const("#{described_class}::POINTS", [ 30, 400 ]) }

    it "reports each point's metrics" do
      expect(point(sweep, 30)[:metrics]).to include(:by_size_class, :orders)
    end

    # The property that makes this a sweep rather than unrelated runs — see
    # `Ablation`'s identical assertion and rationale (ADR-0011). Holds at any
    # point count, so it does not need the real range to mean the same thing.
    it "gives every point the same customers, so a difference is the quantum" do
      [ 1.6, 2.2 ].each do |demand|
        arrived = described_class.call(seed: 7, stations: 3, demand_multiplier: demand)
                                 .map { |p| p[:arrived] }

        expect(arrived.uniq.size).to eq(1),
                                     "at #{demand}× the points saw different customers: #{arrived}"
      end
    end

    it "refuses to run more days than the ceiling" do
      stub_const("#{described_class}::MAX_SEEDS", 2)

      expect(sweep(seeds: 10_000).first[:metrics][:orders])
        .to eq(sweep(seeds: 2).first[:metrics][:orders])
    end

    it "treats a nonsense day count as one day" do
      expect(sweep(seeds: 0).first[:metrics][:orders]).to eq(sweep(seeds: 1).first[:metrics][:orders])
    end

    it "pools several days into one distribution" do
      one = sweep(seeds: 1).first[:metrics][:orders]
      three = sweep(seeds: 3).first[:metrics][:orders]

      expect(three).to be > one * 2
    end
  end
end

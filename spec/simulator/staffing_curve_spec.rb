require "rails_helper"

RSpec.describe Simulator::StaffingCurve do
  def curve(**overrides)
    described_class.call(seed: 7, demand_multiplier: 1.6, **overrides)
  end

  def at(hours, hour) = hours.find { |h| h[:hour] == hour }

  it "covers §10.3's arrival profile, one entry per open hour, ascending" do
    hours = curve.map { |h| h[:hour] }

    expect(hours).to eq((10..20).to_a)
  end

  # The one example that runs the real 1–8 range end to end, so a bug that
  # only shows up at a station count nothing else here tries would still be
  # seen. Every example below narrows the range instead — the mechanism they
  # check does not depend on how wide it is.
  it "reports each hour's chosen stations, its p90, and whether the target was met" do
    row = at(curve, 16)

    expect(row).to include(:stations, :achieved, :p90, :orders, :p90_meaningful)
    expect(described_class::STATIONS_TRIED).to cover(row[:stations])
  end

  it "needs no more stations at the quietest hour than at the busiest one" do
    # §10.3's profile: hour 10 (index 0) is the quietest bucket at 12/hr, hour
    # 16 (index 6) is the lunch-adjacent peak at 52/hr — far enough apart that
    # one day settles it.
    rows = curve

    expect(at(rows, 10)[:stations]).to be <= at(rows, 16)[:stations]
  end

  it "asks for more stations as demand rises, at the same hour" do
    light = at(curve(demand_multiplier: 0.8), 16)[:stations]
    heavy = at(curve(demand_multiplier: 2.4), 16)[:stations]

    expect(heavy).to be >= light
  end

  # Everything below only cares about the mechanism (clamping, reproducing,
  # falling back), never about where in 1..8 the answer lands, so a 3-wide
  # range proves the same thing for a third of the runs.
  context "with a narrowed station range" do
    before { stub_const("#{described_class}::STATIONS_TRIED", (1..3)) }

    # target_seconds: 1 is unreachable at any station count, so this doesn't
    # need multiple days to be unambiguous.
    it "marks an hour unachieved, at the widest count tried, when even the ceiling misses the target" do
      row = at(curve(target_seconds: 1), 16)

      expect(row[:achieved]).to be false
      expect(row[:stations]).to eq(described_class::STATIONS_TRIED.max)
    end

    it "marks every hour achieved at the loosest possible target" do
      rows = curve(target_seconds: 1_000_000)

      expect(rows).to all(include(achieved: true, stations: described_class::STATIONS_TRIED.min))
    end

    it "is reproducible from the seed" do
      expect(curve).to eq(curve)
    end

    it "refuses to run more days than the ceiling" do
      stub_const("#{described_class}::MAX_SEEDS", 2)

      expect(curve(seeds: 10_000)).to eq(curve(seeds: 2))
    end

    it "treats a nonsense day count as one day" do
      expect(curve(seeds: 0)).to eq(curve(seeds: 1))
    end

    it "flags an hour's p90 as not meaningful under 10 pooled orders" do
      row = at(curve, 10)

      expect(row[:p90_meaningful]).to eq(row[:orders] >= 10)
    end
  end

  it "keeps the ceiling at 25 days, mirroring Ablation::MAX_SEEDS" do
    expect(described_class::MAX_SEEDS).to eq(25)
  end
end

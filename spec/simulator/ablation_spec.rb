require "rails_helper"

RSpec.describe Simulator::Ablation do
  # Busy enough that the arms can differ. "Below saturation every scheduler
  # looks identical — the peaks are the entire test" (§10.3), so an ablation run
  # at 1.0× would compare four arms that all had an easy day.
  def ablate(**overrides)
    described_class.call(seed: 7, stations: 3, demand_multiplier: 1.6, **overrides)
  end

  def arm(runs, id) = runs.find { |r| r[:id] == id }

  it "runs §10.5's ladder, least fair to most, with §6.3's two comparison arms" do
    expect(ablate.map { |a| a[:id] })
      .to eq(%w[fifo rr drr drr_aging drr_aging_cohesion sjf])
  end

  # The chart draws bounds apart from the ladder, and it can only do that if the
  # payload says which is which. SJF is not selectable on a store (§6.3) —
  # `UpdateSchedulerConfig` rejects it — so a chart that lists it beside the
  # candidates is offering something the store cannot run.
  it "marks the control, the rungs, and the bound that is not a policy" do
    kinds = ablate.to_h { |a| [ a[:id], a[:kind] ] }

    expect(kinds).to include("fifo" => "control", "drr" => "rung", "sjf" => "bound")
  end

  it "runs every arm on a policy the scheduler actually has a branch for" do
    policies = described_class::ARMS.map { |a| a[:config][:policy] }

    expect(policies).to all(be_in(Scheduler::Config::POLICIES))
  end

  it "reports each arm's metrics" do
    expect(arm(ablate, "drr")[:metrics]).to include(:by_size_class, :cohesion_spread_p90, :orders)
  end

  # The property that makes this an experiment rather than four unrelated runs.
  #
  # The simulator draws each entity from its own substream (ADR-0011), so
  # changing the scheduler must not shift the arrival stream underneath it.
  # Asserted directly rather than trusted: if an arm got an easier day, a
  # difference between two bars would say nothing about the mechanism that
  # changed, and nothing else in the suite would notice.
  #
  # **Arrivals, not completions.** The first version of this compared the number
  # of orders served, which passed only because almost nobody reneges at 1.6×.
  # At 2.2× the arms legitimately serve different numbers — see the example
  # below — so that version was asserting the wrong invariant and would have
  # broken the moment the demand in this file was raised.
  it "gives every arm the same customers, so a difference is the mechanism" do
    [ 1.6, 2.2, 3.0 ].each do |demand|
      arrived = described_class.call(seed: 7, stations: 3, demand_multiplier: demand)
                               .map { |a| a[:arrived] }

      expect(arrived.uniq.size).to eq(1),
                                   "at #{demand}× the arms saw different customers: #{arrived}"
    end
  end

  # The other half of the same coin, and a real property rather than a caveat:
  # a slower arm quotes longer waits, and more customers decline to join (§10.3).
  # "Reneging prices the cost of slowness in lost revenue rather than abstract
  # seconds" — so an arm serving *fewer* orders off identical arrivals is the
  # metric doing its job, not the experiment leaking.
  it "lets the arms serve different numbers of those customers when the shop is slammed" do
    runs = described_class.call(seed: 7, stations: 3, demand_multiplier: 2.2)

    served = runs.map { |a| a[:metrics][:orders] }
    walked = runs.map { |a| a[:metrics][:reneged] }

    expect(served.sum + walked.sum).to eq(runs.sum { |a| a[:arrived] })
  end

  # §6.1's whole claim, and the reason the project exists: equalising barista
  # *time* rather than turns pulls the small-order wait down sharply.
  it "shows DRR beating first-come-first-served for small orders" do
    runs = ablate

    fifo = arm(runs, "fifo")[:metrics][:by_size_class]["1-2"][:p90]
    drr = arm(runs, "drr")[:metrics][:by_size_class]["1-2"][:p90]

    expect(drr).to be < fifo
  end

  # And the cost, which the chart has to show honestly: DRR pays for that with
  # the large orders, which is exactly what aging (§6.2) is for.
  it "shows aging clawing back the large-order tail DRR gave up" do
    runs = ablate

    drr = arm(runs, "drr")[:metrics][:by_size_class]["7+"][:p90]
    aged = arm(runs, "drr_aging")[:metrics][:by_size_class]["7+"][:p90]

    expect(aged).to be < drr
  end

  # §6.3: "FIFO shows you need fairness, RR shows you need *this* fairness."
  # An arm that dispatched identically to the one beside it would be a row on a
  # chart that isolates nothing.
  it "gives round robin and the deficit genuinely different days" do
    runs = ablate

    expect(arm(runs, "rr")[:metrics]).not_to eq(arm(runs, "drr")[:metrics])
  end

  # The finding that made the chart grow a second axis, pinned here so removing
  # the axis breaks something.
  #
  # §6.3 says SJF "starves large orders by construction". That is true when the
  # job is the *order* — but §2 makes the job a **drink**, so SJF picks the
  # cheapest queued drink and a catering order of Thai Teas sails through. On
  # the size-class axis SJF is therefore not the villain §6.3 describes; it is
  # competitive, and on a chart drawn only that way it reads as the best row.
  describe "the shortest-job-first bound" do
    it "does not starve large orders, because §2 makes the job a drink" do
      runs = ablate

      sjf = arm(runs, "sjf")[:metrics][:by_size_class]["7+"][:p90]
      drr = arm(runs, "drr")[:metrics][:by_size_class]["7+"][:p90]

      expect(sjf).to be < drr
    end

    # Where it does the damage instead, and it is not subtle: §6.1's "does your
    # wait depend on what you ordered?", answered as badly as it can be.
    it "punishes the expensive drink instead, which is the axis §6.1 asks about" do
      runs = ablate

      sjf = arm(runs, "sjf")[:metrics][:wait_by_drink_cost]
      drr = arm(runs, "drr")[:metrics][:wait_by_drink_cost]

      expect(sjf[:comparable]).to be(true)
      expect(sjf[:ratio]).to be > drr[:ratio] * 3
    end
  end

  describe "seeds" do
    it "defaults to §10.5's single fixed day" do
      expect(ablate.first[:metrics][:orders]).to be > 0
    end

    # Pooled, not averaged: a mean of several p90s is not a p90 of anything, and
    # the tail is where the arms differ.
    it "pools several days into one distribution" do
      one = ablate(seeds: 1).first[:metrics][:orders]
      three = ablate(seeds: 3).first[:metrics][:orders]

      expect(three).to be > one * 2
    end

    # A run is unbounded compute behind an admin session; four arms multiply it.
    it "refuses to run more days than the ceiling" do
      expect(described_class::MAX_SEEDS).to eq(25)
      expect(ablate(seeds: 10_000).first[:metrics][:orders])
        .to eq(ablate(seeds: described_class::MAX_SEEDS).first[:metrics][:orders])
    end

    it "treats a nonsense day count as one day" do
      expect(ablate(seeds: 0).first[:metrics][:orders]).to eq(ablate(seeds: 1).first[:metrics][:orders])
    end
  end

  it "carries a quantum into every arm, so the chart can be read at the swept value" do
    quiet = ablate(quantum: 30)
    loud = ablate(quantum: 400)

    expect(arm(quiet, "drr")[:metrics]).not_to eq(arm(loud, "drr")[:metrics])
  end

  # FIFO has no quantum to vary — it does not consult one. A test asserting the
  # opposite would be asserting a bug.
  it "leaves the control arm unmoved by the quantum" do
    expect(arm(ablate(quantum: 30), "fifo")[:metrics])
      .to eq(arm(ablate(quantum: 400), "fifo")[:metrics])
  end
end

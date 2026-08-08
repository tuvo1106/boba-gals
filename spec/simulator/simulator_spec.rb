require "simulator_helper"

RSpec.describe Simulator do
  def run(**overrides)
    described_class.run(Simulator::Scenario.new(**overrides))
  end

  # §10.2: "Seed the RNG and surface the seed in the UI. Reproducible bad days
  # are the entire point." A run nobody can replay is an anecdote.
  describe "determinism" do
    it "returns identical metrics for the same seed" do
      expect(run(seed: 7).to_h).to eq(run(seed: 7).to_h)
    end

    it "returns different metrics for different seeds" do
      expect(run(seed: 7).to_h).not_to eq(run(seed: 8).to_h)
    end
  end

  # §10.2: "A 12-hour simulated day completes in well under a second, which is
  # what makes parameter sweeps (thousands of runs) practical."
  it "simulates a full day in well under a second" do
    elapsed = Benchmark.realtime { run(seed: 1) }

    expect(elapsed).to be < 0.5
  end

  describe "the generative model (§10.3)" do
    it "serves every order it generates" do
      metrics = run(seed: 3).to_h

      expect(metrics[:orders]).to be > 100
      expect(metrics[:drinks]).to be > metrics[:orders]
    end

    # "Order size must be heavy-tailed. The catering orders are the entire
    # reason DRR exists." A model without them tests nothing.
    it "produces catering-sized orders" do
      expect(run(seed: 3).to_h[:by_size_class]["7+"][:orders]).to be_positive
    end

    # "Prep time is right-skewed. Drinks occasionally go wrong; they never go
    # faster than possible. Lognormal, not normal."
    it "never samples a negative prep time" do
      rng = Simulator::Rng.new(99)
      samples = Array.new(5_000) { rng.lognormal(40, 0.28) }

      expect(samples.min).to be_positive
      expect(samples.max).to be > 40, "no right tail — the distribution is not skewed"
    end

    it "scales with the demand multiplier" do
      expect(run(seed: 5, demand_multiplier: 2.0).to_h[:orders])
        .to be > run(seed: 5, demand_multiplier: 1.0).to_h[:orders]
    end
  end

  # §10.1's one rule, asserted rather than assumed.
  describe "the one rule (§10.1)" do
    it "dispatches through Scheduler.pick_next" do
      expect(Scheduler).to receive(:pick_next).at_least(20).times.and_call_original

      run(seed: 2, hours: 2)
    end

    it "honours the scheduler config it is given" do
      expect(run(seed: 4, scheduler_config: { policy: :fifo }).to_h[:orders]).to be_positive
    end
  end

  # The design's central claim, measured rather than asserted (§10.4). Load is
  # held constant across the comparison — sweeping the large-order rate without
  # compensating demand changes utilisation, and then the result is about
  # saturation rather than scheduling.
  describe "the fairness claim (§10.4)" do
    def mean_size(rate)
      Simulator::Scenario.new(large_order_rate: rate).size_mix
                         .sum { |k, p| (k.is_a?(Range) ? (k.min + k.max) / 2.0 : k) * p }
    end

    def small_order_p90(policy:, large_rate:, seeds: 6)
      multiplier = mean_size(0.0) / mean_size(large_rate)

      values = (1..seeds).map do |seed|
        described_class.run(Simulator::Scenario.new(
          seed: seed, large_order_rate: large_rate, demand_multiplier: multiplier,
          scheduler_config: { policy: policy }
        )).small_order_p90
      end

      values.sum / values.size
    end

    it "keeps small orders waiting far less under DRR than under FIFO" do
      drr = small_order_p90(policy: :drr, large_rate: 0.12)
      fifo = small_order_p90(policy: :fifo, large_rate: 0.12)

      expect(drr).to be < fifo * 0.75,
        "DRR #{drr.round}s vs FIFO #{fifo.round}s — fair queuing is not earning its keep"
    end

    # "The same test under FIFO shows a clearly rising line. If it doesn't, the
    # generative model isn't stressing the system — fix the model, don't relax
    # the assertion." (§10.4)
    it "shows a clearly rising line under FIFO" do
      flat = small_order_p90(policy: :fifo, large_rate: 0.0)
      loaded = small_order_p90(policy: :fifo, large_rate: 0.12)

      expect(loaded).to be > flat * 1.5,
        "FIFO barely moved — the generative model is not stressing the system"
    end

    it "rises far less steeply under DRR than under FIFO" do
      drr = small_order_p90(policy: :drr, large_rate: 0.12) / small_order_p90(policy: :drr, large_rate: 0.0)
      fifo = small_order_p90(policy: :fifo, large_rate: 0.12) / small_order_p90(policy: :fifo, large_rate: 0.0)

      expect(drr).to be < fifo
    end
  end

  # A simulator that silently drops work reports metrics over a subset, and the
  # subset it drops is the slow tail — so the numbers look better than the shop.
  describe "conservation" do
    it "accounts for every order that arrives" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 3))

      expect(world.completed.size + world.reneged).to eq(world.arrived),
        "#{world.arrived - world.completed.size - world.reneged} orders vanished"
    end

    it "drains the event queue rather than stopping with work outstanding" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 3))

      expect(world.instance_variable_get(:@pending)).to be_empty
    end

    it "finishes every drink of every completed order" do
      orders = described_class.simulate(Simulator::Scenario.new(seed: 3)).completed

      expect(orders).to all(satisfy { |o| o.items.all?(&:finished_at) })
      expect(orders).to all(satisfy { |o| o.ready_at >= o.arrived_at })
    end
  end

  # The four processes the station-availability loop had nowhere to put. Each is
  # listed in §10.3 and each was missing until the event queue landed.
  describe "the processes the event queue enables (§10.2, §10.3)" do
    it "fails roughly remake_rate of drinks and re-queues them" do
      h = run(seed: 42).to_h

      expect(h[:remakes]).to be_positive
      expect(h[:remakes].to_f / h[:drinks]).to be_within(0.015).of(0.02)
    end

    # A remake is a new drink on the same order (§5.2), which is what gives the
    # order a pending remake and therefore §6.4's priority floor. Nothing else
    # in the model reaches that code path.
    it "puts the remake on the original order rather than a new one" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 42))
      remade = world.completed.select { |o| o.items.any?(&:remake?) }

      expect(remade).to be_any
      expect(remade).to all(satisfy { |o| o.items.count > o.items.count(&:remake?) })
    end

    it "collects every completed order, after a delay" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 42))

      expect(world.completed).to all(satisfy(&:picked_up_at))
      expect(world.completed).to all(satisfy { |o| o.picked_up_at > o.ready_at })
    end

    # §9.6's quality timer needs pickup to exist before it can measure anything.
    it "reports a quality breach rate" do
      expect(run(seed: 42).to_h[:quality_breach_rate]).to be_between(0, 1)
    end

    it "generates order-ahead orders, which exercise backward scheduling" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 42))

      expect(world.completed.count(&:promised_at)).to be_positive
    end

    # "Reneging prices the cost of slowness in lost revenue rather than abstract
    # seconds." It must be quiet in a healthy shop and bite in a saturated one —
    # a renege model that fires at low load would understate every wait.
    it "does not renege in a shop that is keeping up" do
      expect(run(seed: 7, demand_multiplier: 1.0).to_h[:reneged]).to eq(0)
    end

    it "reneges sharply once the shop saturates" do
      calm = run(seed: 7, demand_multiplier: 1.0).to_h
      swamped = run(seed: 7, demand_multiplier: 2.5).to_h

      expect(swamped[:station_utilisation]).to be > 0.85
      expect(swamped[:reneged]).to be > calm[:reneged] + 50
    end
  end

  describe "the event queue (§10.2)" do
    it "pops events in time order" do
      q = Simulator::EventQueue.new
      [ 5.0, 1.0, 3.0, 2.0, 4.0 ].each { |t| q.push(t, :order_arrives) }

      expect(Array.new(5) { q.pop.at }).to eq([ 1.0, 2.0, 3.0, 4.0, 5.0 ])
    end

    # Reproducibility from a seed requires ties to break deterministically;
    # otherwise heap layout, which depends on insertion history, decides.
    it "breaks ties on insertion order" do
      q = Simulator::EventQueue.new
      %i[first second third].each { |name| q.push(1.0, name) }

      expect(Array.new(3) { q.pop.type }).to eq(%i[first second third])
    end

    it "is empty when drained" do
      q = Simulator::EventQueue.new.push(1.0, :pickup)

      expect(q.pop).not_to be_nil
      expect(q).to be_empty
      expect(q.pop).to be_nil
    end
  end

  describe "metrics (§10.4)" do
    it "reports percentiles, never a mean" do
      expect(run(seed: 1).to_h[:wait_seconds].keys).to eq(%i[p50 p90 p99])
    end

    it "orders percentiles" do
      w = run(seed: 1).to_h[:wait_seconds]

      expect(w[:p50]).to be <= w[:p90]
      expect(w[:p90]).to be <= w[:p99]
    end

    it "reports waits by size class, so one cannot hide behind another" do
      expect(run(seed: 1).to_h[:by_size_class].keys).to eq([ "1-2", "3-6", "7+" ])
    end

    it "reports utilisation, which is where staffing decisions get made" do
      expect(run(seed: 1).to_h[:station_utilisation]).to be_between(0, 1)
    end

    # Understating utilisation understates how close the shop is to saturation,
    # which is the number §10.4 says staffing decisions are made on.
    it "measures utilisation from time stations were actually occupied" do
      drinks = described_class.simulate(Simulator::Scenario.new(seed: 1)).completed.flat_map(&:items)

      # Skill is U(0.85, 1.20) and fatigue multiplies, so service time differs
      # from raw prep time on essentially every drink.
      expect(drinks.count { |d| d.service_seconds != d.actual_prep_seconds }).to eq(drinks.size)
      expect(drinks).to all(satisfy { |d| (d.finished_at - d.started_at - d.service_seconds).abs < 0.001 })
    end

    it "reports cohesion spread, the melted-first-drink measure" do
      expect(run(seed: 1).to_h[:cohesion_spread_p90]).to be >= 0
    end

    it "is empty rather than broken for a shop with no arrivals" do
      expect(run(seed: 1, arrival_profile: [ 0 ]).to_h[:orders]).to eq(0)
    end
  end
end

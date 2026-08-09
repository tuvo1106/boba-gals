module Simulator
  # §10.5's first experiment: "Ablation on a fixed seed: FIFO → DRR → DRR+aging
  # → DRR+aging+cohesion. Four bars, one chart. **This is the proof the design
  # works.**"
  #
  # Each arm turns on exactly one more thing than the arm before it, so a
  # difference between two adjacent bars is attributable to the one feature that
  # changed. That is the whole value of an ablation over several unrelated runs.
  #
  # §10.5 names four arms; this runs six. The two extra are §6.3's comparison
  # arms, which exist precisely because "FIFO alone cannot separate the two
  # claims this design actually makes" — `rr` is the missing rung between FIFO
  # and DRR (it is DRR with the deficit removed), and `sjf` is the bound, not a
  # rung. Both are simulator-only and neither is selectable on a store.
  #
  # **The arms share their customers.** Every arm runs the same seed, and the
  # simulator draws each entity from its own substream (ADR-0011), so changing
  # the scheduler does not shift the arrival stream underneath it. Without that,
  # an arm could look better because it happened to get an easier day — which is
  # the failure mode that makes a benchmark worthless, and is asserted directly
  # in the specs rather than assumed from the ADR.
  class Ablation
    # In §10.5's order, least fair to most: each row adds one mechanism.
    #
    # `fifo` is the control. `rr` and `drr` are the two halves of §6.3's first
    # claim — FIFO shows you need fairness, RR shows you need *this* fairness.
    # Aging (§6.2) is next because it exists to stop DRR starving anyone.
    # Cohesion (§6.4) is last and ships **disabled** (ADR-0014) — it did not
    # reduce spread when measured, and this chart is where that shows rather
    # than being asserted.
    #
    # `kind` separates the ladder from the two things that are not rungs on it:
    # the control everything is measured against, and SJF, which is a bound
    # rather than a candidate. The chart draws them apart for that reason —
    # reading SJF as "the best row" is the specific misreading §6.3 warns about.
    ARMS = [
      {
        id: "fifo",
        kind: "control",
        label: "First come, first served",
        blurb: "The control. Every drink in arrival order — best for the catering order, worst for everyone behind it.",
        config: { policy: :fifo, aging_enabled: false, cohesion_enabled: false }
      },
      {
        id: "rr",
        kind: "rung",
        label: "Round robin",
        blurb: "Orders take turns, one drink each. Equal turns, not equal time — a 135s drink counts the same as a 40s one (§6.3).",
        config: { policy: :rr, aging_enabled: false, cohesion_enabled: false }
      },
      {
        id: "drr",
        kind: "rung",
        label: "+ the deficit",
        blurb: "Turns are now measured in barista seconds, so an order of expensive drinks gets fewer of them (§6.1).",
        config: { policy: :drr, aging_enabled: false, cohesion_enabled: false }
      },
      {
        id: "drr_aging",
        kind: "rung",
        label: "+ aging",
        blurb: "Anyone waiting far longer than the rest gets pulled forward (§6.2).",
        config: { policy: :drr, aging_enabled: true, cohesion_enabled: false }
      },
      {
        id: "drr_aging_cohesion",
        kind: "rung",
        label: "+ cohesion",
        blurb: "An order past half made is finished off, so the first drink sits less (§6.4). Ships disabled — ADR-0014.",
        config: { policy: :drr, aging_enabled: true, cohesion_enabled: true }
      },
      {
        id: "sjf",
        kind: "bound",
        label: "Shortest job first",
        blurb: "Not a candidate — the bound DRR is paying against. It wins on every average, and charges for it on drink cost: switch the axis to see who pays (§6.3).",
        config: { policy: :sjf, aging_enabled: false, cohesion_enabled: false }
      }
    ].freeze

    # Two caveats a reader of this chart deserves, both measured rather than
    # reasoned about.
    #
    # **SJF does not starve large orders, so the size-class chart makes it look
    # like the best row.** This is ADR-0013's finding, not a new one: "SJF
    # starves *expensive drinks*, not *large orders*", because §2 makes the job
    # a drink and §10.3's menu draws drink cost independently of order size, so
    # a catering order has twenty chances to hold a cheap one. Reproduced here
    # at a different operating point — seed 7, 3 stations, 5 days — where SJF's
    # 7+ p90 beats DRR's at every demand tried (1604s vs 2243s at 1.6×).
    #
    # Its damage lands on the other axis, and it is enormous: the dear/cheap p90
    # ratio runs 6.1 / 11.5 / 38.2 at 1.0× / 1.6× / 2.2×, against DRR's
    # 1.8 / 2.2 / 2.0. At 2.2× a Brown Sugar Pearl waits 3973s while a Thai Tea
    # waits 104s. That is §6.1's question — "does your wait depend on what you
    # ordered?" — answered as badly as it can be, and it is the same separation
    # ADR-0013 measured as a 19.63× slow-drink penalty.
    #
    # Hence the axis toggle on the chart. §6.3's claim that SJF "starves large
    # orders by construction" is the reason it is safe to put SJF on a public
    # chart at all, and it is the one thing the size-class view disproves — so
    # drawn only that way, this chart would argue against the design.
    #
    # **The `rr` → `+ the deficit` step is not purely the deficit.** `pick_rr`
    # walks `state.flows` while DRR walks `priority_ring`, so that step also
    # switches on §6.4's remake floor. Remakes are ~2% of drinks at the seeded
    # rates, so the contamination is small — but it is not zero, and "one
    # mechanism per step" is a claim this file should not make more strongly
    # than it can support.

    # A run is a few hundred milliseconds and this multiplies by the arm count,
    # so the ceiling is on the number of *days*, not on the arms.
    MAX_SEEDS = 25

    # @param seed [Integer] the first seed; further seeds count up from it
    # @param stations [Integer]
    # @param demand_multiplier [Float]
    # @param seeds [Integer] days per arm, pooled. One is §10.5's "fixed seed";
    #   more is how you tell a real difference from one unlucky Tuesday.
    # @param quantum [Integer, nil] carried into every arm, so the ablation can
    #   be read at whatever quantum the sweep settled on
    # @return [Array<Hash>] one entry per arm, in ARMS order
    def self.call(seed: 1, stations: 3, demand_multiplier: 1.0, seeds: 1, quantum: nil)
      days = seeds.clamp(1, MAX_SEEDS)

      ARMS.map do |arm|
        metrics, arrived = run_arm(arm, seed: seed, stations: stations,
                                        demand_multiplier: demand_multiplier, days: days, quantum: quantum)

        # `arrived` and not just the served count. They are the same number in a
        # quiet shop and diverge in a busy one, because a slower arm quotes
        # longer waits and more customers decline to join (§10.3) — so
        # *completions legitimately differ between arms* while arrivals must
        # not. Arrivals identical is the property that makes this an experiment;
        # completions identical would be an accident of low demand.
        arm.slice(:id, :kind, :label, :blurb).merge(arrived: arrived, metrics: metrics.to_h)
      end
    end

    # Percentiles are computed over the **pooled** orders of every day, not
    # averaged across days. A mean of four p90s is not a p90 of anything, and
    # the tail is exactly where these arms differ.
    # @return [Array(Simulator::Metrics, Integer)] the arm's metrics, and how
    #   many customers walked in across every pooled day
    def self.run_arm(arm, seed:, stations:, demand_multiplier:, days:, quantum:)
      orders = []
      seconds = 0.0
      reneged = 0
      remakes = 0
      arrived = 0

      days.times do |day|
        world = Simulator.simulate(scenario_for(arm, seed + day, stations, demand_multiplier, quantum))

        orders.concat(world.completed)
        seconds += world.clock
        reneged += world.reneged
        remakes += world.remakes
        arrived += world.arrived
      end

      [ Metrics.new(orders: orders, seconds: seconds, stations: stations,
                    reneged: reneged, remakes: remakes), arrived ]
    end
    private_class_method :run_arm

    def self.scenario_for(arm, seed, stations, demand_multiplier, quantum)
      config = arm[:config]
      config = config.merge(quantum: quantum) if quantum

      Scenario.new(seed: seed, stations: stations,
                   demand_multiplier: demand_multiplier, scheduler_config: config)
    end
    private_class_method :scenario_for
  end
end

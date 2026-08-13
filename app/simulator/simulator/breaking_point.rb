module Simulator
  # §10.5's fourth experiment: "Breaking point: raise the demand multiplier
  # until p90 exceeds 15 min. That number is the store's real capacity."
  #
  # Unlike `Ablation` and `QuantumSweep`, this one is asked to *answer* a
  # number rather than hand back a curve for the reader to eyeball (contrast
  # `QuantumSweepChart`, which deliberately does not compute the crossover
  # itself). So alongside every point tried, `call` reports the first demand
  # multiplier whose p90 crossed the target — `capacity`, `nil` if nothing in
  # `POINTS` crossed it, the same "ceiling, not an answer" convention
  # `StaffingCurve#achieved` uses.
  #
  # **Overall p90, not the small-order figure §10.4 calls the headline.**
  # §10.4's headline asks whether fair queuing is working — whether the
  # small order's wait stays flat as large orders arrive. Capacity asks a
  # different question: can the shop serve this demand at all, for a typical
  # customer, regardless of what they ordered. Reneging (§10.3) is what makes
  # "capacity" a well-defined question in the first place — without it the
  # queue grows without bound and every demand multiplier "breaks" eventually
  # given a long enough day. ADR-0021 has the reasoning, and why the swept
  # range stops at 3x rather than searching further.
  #
  # Runs DRR with the store's other defaults untouched (aging on, cohesion
  # off), the same reasoning `QuantumSweep` gives: the question is what
  # demand alone does to a config a store would actually run.
  class BreakingPoint
    # 0.5x up to 3x — the dashboard's demand slider ceiling (§10.6) — dense
    # through 2.5x where the crossover typically sits (seed 7 at 3 stations
    # crosses between 1.5x and 1.75x), sparser toward 3x.
    #
    # **Capped at 3x deliberately, on cost, not on curiosity.** Reneging keeps
    # the shop's queue bounded, but a bounded queue is still a *big* one at
    # extreme demand, and dispatch cost rises with it: benchmarked at this
    # seed and station count, one simulated day costs 0.03s at 0.5x and 83s
    # at 5x — worse than linear, because a deeper queue means more dispatch
    # cycles and a larger priority ring to scan each time (§6.2's aging).
    # Every point beyond 3x roughly doubled the point before it. 3x is
    # already past where a real shop would consider adding stations instead
    # of asking this question, and `capacity: nil` reports honestly when a
    # config holds past it rather than silently paying for points nobody
    # asked for.
    POINTS = [ 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0 ].freeze

    # 15 minutes — §10.5 #4's own number.
    TARGET_SECONDS = 900

    # Mirrors `Ablation::MAX_SEEDS` — a run is a few hundred milliseconds and
    # this multiplies by the point count, so the ceiling is on the number of
    # *days*, not on the points.
    MAX_SEEDS = 25

    # @param seed [Integer] the first seed; further seeds count up from it
    # @param stations [Integer]
    # @param seeds [Integer] days per point, pooled — see `Ablation` for why
    #   pooling rather than averaging
    # @param target_seconds [Numeric] the p90 that marks the shop as broken
    # @return [Hash] `{ points:, capacity: }` — points in ascending demand
    #   order, capacity the first demand multiplier to cross the target
    def self.call(seed: 1, stations: 3, seeds: 1, target_seconds: TARGET_SECONDS)
      days = seeds.clamp(1, MAX_SEEDS)

      points = POINTS.map do |demand_multiplier|
        metrics, arrived = run_point(demand_multiplier, seed: seed, stations: stations, days: days)

        { demand_multiplier: demand_multiplier, arrived: arrived, metrics: metrics.to_h }
      end

      breaking = points.find { |point| point[:metrics][:wait_seconds][:p90] > target_seconds }

      { points: points, capacity: breaking&.fetch(:demand_multiplier) }
    end

    # @return [Array(Simulator::Metrics, Integer)] the point's pooled metrics,
    #   and how many customers arrived across every pooled day
    def self.run_point(demand_multiplier, seed:, stations:, days:)
      orders = []
      seconds = 0.0
      reneged = 0
      remakes = 0
      arrived = 0

      days.times do |day|
        world = Simulator.simulate(scenario_for(demand_multiplier, seed + day, stations))

        orders.concat(world.completed)
        seconds += world.clock
        reneged += world.reneged
        remakes += world.remakes
        arrived += world.arrived
      end

      [ Metrics.new(orders: orders, seconds: seconds, stations: stations,
                    reneged: reneged, remakes: remakes), arrived ]
    end
    private_class_method :run_point

    def self.scenario_for(demand_multiplier, seed, stations)
      Scenario.new(seed: seed, stations: stations, demand_multiplier: demand_multiplier,
                   scheduler_config: { policy: :drr })
    end
    private_class_method :scenario_for
  end
end

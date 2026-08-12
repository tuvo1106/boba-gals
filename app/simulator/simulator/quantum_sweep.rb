module Simulator
  # §10.5's second experiment: "Quantum sweep: 30s → 400s, plot small-order p90
  # and large-order p90 together. The crossover is your setting."
  #
  # A small quantum grants small-order flows tiny turns and revisits them
  # often, so their wait tracks demand closely. A large quantum lets a flow
  # hold a station for a long stretch once granted, which favours whichever
  # order is already running — the trade §6.1 makes explicit. This experiment
  # is where that trade gets a number instead of an intuition.
  #
  # **Every point shares its customers**, the same way `Ablation` does
  # (ADR-0011): each point is a fresh scenario at `seed + day`, so the *i*-th
  # day is identical across every quantum tried and a difference between two
  # points is the quantum, not a luckier Tuesday.
  #
  # Runs DRR with the store's other defaults untouched — aging on, cohesion
  # off (`Scheduler::Config::DEFAULTS`) — because the question is what the
  # quantum alone does to a config a store would actually run, not an isolated
  # mechanism the way the ablation's ladder is built.
  class QuantumSweep
    # Ten points spanning §10.5's own range, denser near the 60s default
    # (`Scheduler::Config::DEFAULTS[:quantum]`) where the crossover is
    # expected to sit, sparser toward the far end where the answer is just
    # "yes, still favouring the large order".
    POINTS = [ 30, 45, 60, 90, 120, 150, 180, 240, 300, 400 ].freeze

    # Mirrors `Ablation::MAX_SEEDS` — a run is a few hundred milliseconds and
    # this multiplies by the point count, so the ceiling is on the number of
    # *days*, not on the points.
    MAX_SEEDS = 25

    # @param seed [Integer] the first seed; further seeds count up from it
    # @param stations [Integer]
    # @param demand_multiplier [Float]
    # @param seeds [Integer] days per point, pooled — see `Ablation` for why
    #   pooling rather than averaging
    # @return [Array<Hash>] one entry per point, in ascending quantum order
    def self.call(seed: 1, stations: 3, demand_multiplier: 1.0, seeds: 1)
      days = seeds.clamp(1, MAX_SEEDS)

      POINTS.map do |quantum|
        metrics, arrived = run_point(quantum, seed: seed, stations: stations,
                                               demand_multiplier: demand_multiplier, days: days)

        { quantum: quantum, arrived: arrived, metrics: metrics.to_h }
      end
    end

    # @return [Array(Simulator::Metrics, Integer)] the point's pooled metrics,
    #   and how many customers arrived across every pooled day
    def self.run_point(quantum, seed:, stations:, demand_multiplier:, days:)
      orders = []
      seconds = 0.0
      reneged = 0
      remakes = 0
      arrived = 0

      days.times do |day|
        world = Simulator.simulate(scenario_for(quantum, seed + day, stations, demand_multiplier))

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

    def self.scenario_for(quantum, seed, stations, demand_multiplier)
      Scenario.new(seed: seed, stations: stations, demand_multiplier: demand_multiplier,
                   scheduler_config: { policy: :drr, quantum: quantum })
    end
    private_class_method :scenario_for
  end
end

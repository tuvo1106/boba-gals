module Simulator
  # Everything a run needs, and the §10.3 defaults (DESIGN.md §10.3).
  #
  # The numbers here are load-bearing, not placeholders. §10.3 is explicit about
  # why each shape matters, and the notes below carry those reasons because a
  # future reader flattening one of them would break the experiment without any
  # test failing.
  class Scenario
    # Orders per hour, 10:00 to 21:00. Lunch, after-school and evening peaks.
    #
    # "Flat arrivals will make everything look fine." A uniform rate keeps the
    # shop below saturation all day, and every scheduler looks identical below
    # saturation — the peaks are the entire test.
    DEFAULT_ARRIVAL_PROFILE = [ 12, 22, 48, 40, 26, 38, 52, 44, 36, 42, 24 ].freeze

    # "Order size must be heavy-tailed. The catering orders are the entire
    # reason DRR exists." A Poisson or geometric size distribution would almost
    # never produce the 15-drink order the design exists to handle.
    DEFAULT_SIZE_MIX = {
      1 => 0.62, 2 => 0.22, 3 => 0.09,
      (4..6) => 0.04, (8..20) => 0.03
    }.freeze

    OPENS_AT = 10 # 10:00, matching the profile's first bucket

    attr_reader :seed, :stations, :hours, :arrival_profile, :size_mix,
                :demand_multiplier, :large_order_rate, :scheduler_config,
                :menu, :prep_sigma, :remake_rate

    # @param seed [Integer] the whole run is a function of this
    # @param menu [Array<Hash>] `[{ name:, prep_seconds:, weight: }, ...]`
    # @param large_order_rate [Float, nil] overrides the 8–20 drink share, which
    #   is the x-axis of §10.4's headline chart
    def initialize(seed: 1, stations: 3, hours: DEFAULT_ARRIVAL_PROFILE.size,
                   arrival_profile: DEFAULT_ARRIVAL_PROFILE, size_mix: DEFAULT_SIZE_MIX,
                   demand_multiplier: 1.0, large_order_rate: nil,
                   scheduler_config: {}, menu: nil, prep_sigma: 0.28, remake_rate: 0.02)
      @seed = seed
      @stations = stations
      @hours = hours
      @arrival_profile = arrival_profile
      @size_mix = large_order_rate ? rebalanced_mix(size_mix, large_order_rate) : size_mix
      @demand_multiplier = demand_multiplier
      @large_order_rate = large_order_rate
      @scheduler_config = scheduler_config
      @menu = menu || DEFAULT_MENU
      @prep_sigma = prep_sigma
      @remake_rate = remake_rate
    end

    # A spread wide enough that fairness is a real question. "A menu where
    # everything takes the same time would hide the problem the scheduler exists
    # to solve" (§1) — with uniform prep times, round robin and DRR agree.
    DEFAULT_MENU = [
      { name: "Thai Tea", prep_seconds: 40, weight: 3 },
      { name: "Classic Milk Tea", prep_seconds: 45, weight: 4 },
      { name: "Taro Slush", prep_seconds: 70, weight: 2 },
      { name: "Brown Sugar Pearl", prep_seconds: 95, weight: 2 }
    ].freeze

    # @return [Scheduler::Config]
    def config
      Scheduler::Config.from_store(Scheduler::Config::DEFAULTS.merge(@scheduler_config))
    end

    # @return [Float] orders per second during the given simulated hour
    def arrival_rate_at(hour_index)
      per_hour = arrival_profile[hour_index] || 0

      per_hour * demand_multiplier / 3600.0
    end

    # @return [Integer] the busiest rate, used for Poisson thinning (§10.3)
    def peak_rate
      (arrival_profile.max * demand_multiplier) / 3600.0
    end

    def duration_seconds
      hours * 3600
    end

    private

    # The headline chart sweeps large-order rate 0%–12% (§10.4), so that share
    # has to be settable without rewriting the whole mixture. The remaining mass
    # is redistributed proportionally so the sizes still sum to 1.
    def rebalanced_mix(mix, rate)
      large_key = mix.keys.find { |k| k.is_a?(Range) && k.min >= 8 }
      others = mix.except(large_key)
      scale = (1.0 - rate) / others.values.sum

      others.transform_values { |v| v * scale }.merge(large_key => rate)
    end
  end
end

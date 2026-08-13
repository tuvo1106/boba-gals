module Simulator
  # §10.5's third experiment: "Staffing curve: for each hour, minimum stations
  # holding p90 under target. Output is an actual shift schedule."
  #
  # §10.4 sets up the business question this answers: reneging is what turns
  # "p90 is 100 minutes, hire two more baristas" into "p90 is 31 minutes and
  # you lose 146 customers" — an actual trade against the cost of a shift,
  # not a queue that could never have formed. The staffing curve is what
  # turns that one comparison into eleven, one per open hour.
  #
  # **Method, and its limit.** The simulator has no notion of stations coming
  # on or off mid-shift — `Scenario#stations` is one number for the whole day
  # (§10.1). So this does not simulate a variable roster; it runs the *whole
  # day* at each candidate count in `STATIONS_TRIED`, buckets completed orders
  # by the hour they arrived, and for each hour reports the smallest count
  # whose bucket cleared `target_seconds` at p90. That answers "if the shop
  # ran all day at N stations, would this hour be fine?", which is not quite
  # "what should hour H be staffed at" — it cannot see one understaffed
  # hour's queue spilling into the next the way a true variable-capacity run
  # would. See ADR-0020 for the reasoning and what a truer version would need.
  #
  # **Every station count shares its customers**, the same way `Ablation` and
  # `QuantumSweep` do (ADR-0011): each count is run at the same seed + day, so
  # a difference between two counts is the staffing and not a luckier
  # Tuesday. Unlike those two, this sweeps a variable the arrival stream
  # cannot be fully blind to: more stations means shorter quotes, which means
  # fewer web customers renege (§10.3), so a busier bucket can legitimately
  # gain *more* completed orders — not just faster ones — as the count rises.
  class StaffingCurve
    # Hand-picked over an exhaustive range: a real shop staffs in whole
    # baristas, and beyond 8 the marginal station stops mattering at any
    # demand the dashboard's slider reaches (3x max, §10.6).
    STATIONS_TRIED = (1..8).freeze

    # Ten minutes. Not in DESIGN.md — no figure is — so this is a dashboard
    # knob (`target_seconds`) with this as its default, not a number a store
    # is bound to.
    DEFAULT_TARGET_SECONDS = 600

    # Mirrors `Ablation::MAX_SEEDS` — a run is a few hundred milliseconds and
    # this multiplies by the station-count range, so the ceiling is on the
    # number of *days*, not on the counts tried.
    MAX_SEEDS = 25

    # Same floor `Metrics::P90_MIN_SAMPLES` uses, for the same reason: an
    # hour's p90 over a handful of orders is close to its maximum, not a
    # percentile.
    MIN_SAMPLES = 10

    # @param seed [Integer] the first seed; further seeds count up from it
    # @param demand_multiplier [Float]
    # @param seeds [Integer] days pooled per station count
    # @param target_seconds [Numeric] the p90 an hour's bucket must clear
    # @return [Array<Hash>] one entry per open hour, ascending — the schedule
    def self.call(seed: 1, demand_multiplier: 1.0, seeds: 1, target_seconds: DEFAULT_TARGET_SECONDS)
      days = seeds.clamp(1, MAX_SEEDS)
      hours = Scenario::DEFAULT_ARRIVAL_PROFILE.size

      runs = STATIONS_TRIED.map do |stations|
        orders = run_stations(stations, seed: seed, demand_multiplier: demand_multiplier, days: days)

        { stations: stations, by_hour: bucket(orders, hours) }
      end

      (0...hours).map { |hour| curve_for(hour, runs, target_seconds) }
    end

    # @return [Array<Simulator::Order>] completed orders, pooled over the days
    def self.run_stations(stations, seed:, demand_multiplier:, days:)
      orders = []

      days.times do |day|
        world = Simulator.simulate(scenario_for(stations, seed + day, demand_multiplier))
        orders.concat(world.completed)
      end

      orders
    end
    private_class_method :run_stations

    def self.scenario_for(stations, seed, demand_multiplier)
      Scenario.new(seed: seed, stations: stations, demand_multiplier: demand_multiplier,
                   scheduler_config: { policy: :drr })
    end
    private_class_method :scenario_for

    # @return [Array<Hash>] one entry per hour index: `{ orders:, p90: }`
    def self.bucket(orders, hours)
      buckets = Array.new(hours) { [] }

      orders.each do |order|
        index = (order.arrived_at / 3600).floor.clamp(0, hours - 1)
        buckets[index] << order.wait_seconds
      end

      buckets.map { |waits| { orders: waits.size, p90: percentile(waits, 90) } }
    end
    private_class_method :bucket

    # The smallest station count in `STATIONS_TRIED` whose bucket for this
    # hour cleared the target; the largest count tried, marked unachieved, if
    # none did — the honest answer to "we tried up to 8 and it still
    # doesn't hold" is to say so, not to silently report 8 as if it worked.
    def self.curve_for(hour, runs, target_seconds)
      hit = runs.find { |run| run[:by_hour][hour][:p90] <= target_seconds }
      chosen = hit || runs.last
      row = chosen[:by_hour][hour]

      {
        hour: Scenario::OPENS_AT + hour,
        stations: chosen[:stations],
        achieved: !hit.nil?,
        p90: row[:p90],
        orders: row[:orders],
        p90_meaningful: row[:orders] >= MIN_SAMPLES
      }
    end
    private_class_method :curve_for

    # Nearest-rank, matching `Metrics#percentile` — interpolation would
    # invent a wait nobody had.
    def self.percentile(values, rank)
      return 0.0 if values.empty?

      sorted = values.compact.sort
      index = ((rank / 100.0) * sorted.size).ceil - 1

      sorted[index.clamp(0, sorted.size - 1)].to_f.round(1)
    end
    private_class_method :percentile
  end
end

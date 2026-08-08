module Simulator
  # What a run reports (DESIGN.md §10.4).
  #
  # "Report p50 / p90 / p99 — never the mean. The mean hides exactly the
  # failures fair queuing exists to prevent." A shop where 95% of customers wait
  # two minutes and 5% wait twenty has a fine mean and a real problem, and the
  # 5% are precisely the customers standing behind a catering order.
  class Metrics
    # §10.4 reports waits by size class, because the whole claim is about how
    # these three move *relative to each other*. A single aggregate would let a
    # scheduler that starves large orders look like an improvement.
    SIZE_CLASSES = {
      "1-2" => (1..2),
      "3-6" => (3..6),
      "7+" => (7..Float::INFINITY)
    }.freeze

    # @param orders [Array<Simulator::Order>] completed orders
    # @param seconds [Numeric] simulated duration
    # @param stations [Integer]
    def initialize(orders:, seconds:, stations:, reneged: 0, remakes: 0)
      @orders = orders
      @seconds = seconds
      @stations = stations
      @reneged = reneged
      @remakes = remakes
    end

    # @return [Hash]
    def to_h
      {
        orders: @orders.size,
        drinks: @orders.sum { |o| o.items.size },
        wait_seconds: percentiles(@orders.map(&:wait_seconds)),
        by_size_class: by_size_class,
        # Past ~85% queues grow nonlinearly — this is where staffing decisions
        # get made (§10.4).
        station_utilisation: utilisation,
        # p90 of ready_at − first_ready_at: the melted-first-drink problem, and
        # the direct measure of whether cohesion is working (§10.4, §6.4).
        cohesion_spread_p90: percentile(@orders.map(&:cohesion_spread), 90),
        max_queue_depth: @orders.map(&:queue_depth_on_arrival).max || 0,
        # §9.6: a drink sitting longer than quality_limit_seconds after it was
        # finished. Multi-drink orders are the main source, so this is how the
        # cohesion boost is judged (§10.4).
        quality_breach_rate: breach_rate,
        # "Reneging prices the cost of slowness in lost revenue rather than
        # abstract seconds." (§10.3)
        reneged: @reneged,
        remakes: @remakes
      }
    end

    # The headline: small-order p90. "If fair queuing is working, that line is
    # flat. If it slopes up, the quantum is too large." (§10.4)
    # @return [Float]
    def small_order_p90
      percentile(orders_in("1-2").map(&:wait_seconds), 90)
    end

    private

    def by_size_class
      SIZE_CLASSES.keys.index_with do |label|
        waits = orders_in(label).map(&:wait_seconds)

        { orders: waits.size }.merge(percentiles(waits))
      end
    end

    def orders_in(label)
      range = SIZE_CLASSES.fetch(label)

      @orders.select { |o| range.cover?(o.items.size) }
    end

    def percentiles(values)
      { p50: percentile(values, 50), p90: percentile(values, 90), p99: percentile(values, 99) }
    end

    # Nearest-rank. Interpolation invents values between observations, which for
    # a p99 over a few hundred orders means reporting a wait nobody had.
    def percentile(values, rank)
      return 0.0 if values.empty?

      sorted = values.compact.sort
      index = ((rank / 100.0) * sorted.size).ceil - 1

      sorted[index.clamp(0, sorted.size - 1)].to_f.round(1)
    end

    QUALITY_LIMIT = 300

    def breach_rate
      collected = @orders.filter_map(&:sat_seconds)
      return 0.0 if collected.empty?

      (collected.count { |s| s > QUALITY_LIMIT }.to_f / collected.size).round(3)
    end

    def utilisation
      # service_seconds, not actual_prep_seconds: a station is occupied for the
      # drink's time scaled by that barista's skill and any fatigue.
      busy = @orders.sum { |o| o.items.sum(&:service_seconds) }
      capacity = @seconds * @stations

      return 0.0 if capacity.zero?

      (busy / capacity).round(3)
    end
  end
end

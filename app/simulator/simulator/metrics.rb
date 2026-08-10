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
        # finished. Split because a single-drink order's sitting time *is* the
        # customer's walk-up delay — nothing the scheduler can affect — which
        # puts a floor near 10% under any aggregate figure. Multi-drink orders
        # are where cohesion is judged (§10.4, §6.4).
        # "Does your wait depend on what you ordered?" — the sharpest single
        # number for what equalising *time* rather than *jobs* buys (§6.1).
        # SJF spreads these 14x apart; DRR keeps them within ~15%.
        wait_by_drink_cost: wait_by_drink_cost,
        # §10.4: "ETA error (p50 abs) **and bias** (signed mean) — bias is the
        # one that destroys trust."
        eta_accuracy: eta_accuracy,
        quality_breach_rate: breach_rate(@orders),
        quality_breach_rate_multi: breach_rate(@orders.reject { |o| o.items.size == 1 }),
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

    # A p90 over 5 observations is the maximum, not a percentile — nearest-rank
    # lands on the last element for any n below 10. Reporting one next to a p90
    # over 300 orders invites a comparison that is really "one bad catering
    # order" against "a distribution", so the count travels with the figure and
    # `p90_meaningful` says outright whether it is one.
    P90_MIN_SAMPLES = 10

    def by_size_class
      SIZE_CLASSES.keys.index_with do |label|
        waits = orders_in(label).map(&:wait_seconds)

        { orders: waits.size, p90_meaningful: waits.size >= P90_MIN_SAMPLES }.merge(percentiles(waits))
      end
    end

    # What the customer was told against what happened (§10.4, §7.3).
    #
    # **The signed mean is deliberate, and it is the one exception to this
    # file's own rule.** §10.4 opens with "never the mean" because a mean hides
    # a bad tail — but here the tail is not the question. Bias asks whether the
    # shop is *systematically* late, and a median signed error cannot see it: a
    # shop that beats its quote by a second on half of orders and is four
    # minutes late on the other half has a median near zero and a trust problem.
    # Absolute error and bias answer different questions, so §10.4 asks for
    # both, and neither alone is enough.
    #
    # Measured on the §7.1 projection: at 1.0x demand the bias is about +2.5s
    # against a 60s median quote, so the estimator is close to unbiased. The
    # figure was +142s until `ProjectEta#order_ahead` was fixed — every bit of
    # that was order-ahead customers quoted zero seconds and then "waiting"
    # their whole two-hour horizon.
    def eta_accuracy
      errors = @orders.filter_map(&:eta_error)
      capped = @orders.count(&:quote_capped)

      return { orders: 0, capped: capped, measurable: false, p50_abs: 0.0, p90_abs: 0.0, bias: 0.0 } if errors.empty?

      {
        orders: errors.size,
        # Quotes that hit the projection horizon, excluded above because they
        # are a floor rather than an estimate (`Projection::HORIZON_SECONDS`).
        # Surfaced rather than dropped silently: a run where most orders are
        # capped is a saturated shop, and the accuracy figures describe only the
        # customers who got a real answer.
        capped: capped,
        measurable: errors.size >= P90_MIN_SAMPLES,
        p50_abs: percentile(errors.map(&:abs), 50),
        p90_abs: percentile(errors.map(&:abs), 90),
        bias: (errors.sum / errors.size).round(1)
      }
    end

    # Cheap and dear are the ends of §10.3's menu — Thai Tea at 40s against a
    # Brown Sugar Pearl at 95s. Restricted to small orders so order size cannot
    # confound it: every order here is 1-2 drinks, and the only thing varying is
    # what those drinks cost to make.
    CHEAP_SECONDS = 50
    DEAR_SECONDS = 90

    # Queueing time, not wait. A Brown Sugar Pearl takes 95s to make against a
    # Thai Tea's 40s whatever the scheduler does, so comparing *waits* would
    # report a 2.4x penalty in an empty shop and call it unfairness. What the
    # scheduler controls is the time before your drink is started, and that is
    # the only part this ratio may contain.
    def wait_by_drink_cost
      small = orders_in("1-2")
      cheap = small.select { |o| mean_prep(o) <= CHEAP_SECONDS }.map(&:queue_seconds)
      dear = small.select { |o| mean_prep(o) >= DEAR_SECONDS }.map(&:queue_seconds)

      cheap_p90 = percentile(cheap, 90)
      dear_p90 = percentile(dear, 90)

      {
        cheap: { orders: cheap.size, p90: cheap_p90 },
        dear: { orders: dear.size, p90: dear_p90 },
        # A ratio of 1.0 means the two sides queued alike. Zero means one side
        # had nothing in it, which is not a good score — hence `comparable`:
        # without it, an empty run reports 0.00x and reads as perfect fairness,
        # the same way a p90 over five orders read as a percentile.
        comparable: cheap.size >= P90_MIN_SAMPLES && dear.size >= P90_MIN_SAMPLES,
        ratio: cheap_p90.zero? ? 0.0 : (dear_p90 / cheap_p90).round(2)
      }
    end

    # By what was ordered, not by what was made: a remake is a fresh draw from
    # the menu (§5.2) and would reclassify the order the customer placed.
    def mean_prep(order)
      ordered = order.ordered_items

      ordered.sum(&:prep_seconds) / ordered.size.to_f
    end

    # Keyed on what the customer ordered, not on how many drinks were made.
    def orders_in(label)
      range = SIZE_CLASSES.fetch(label)

      @orders.select { |o| range.cover?(o.ordered_size) }
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

    # Per drink, per §9.6 — not per order. `sat_seconds` returns one figure per
    # finished drink, so an order contributes as many observations as it had
    # drinks sitting.
    def breach_rate(orders)
      sat = orders.flat_map(&:sat_seconds)
      return 0.0 if sat.empty?

      (sat.count { |s| s > QUALITY_LIMIT }.to_f / sat.size).round(3)
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

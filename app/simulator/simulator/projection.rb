module Simulator
  # The quote a customer is given, projected the way §7.1 specifies.
  #
  # "Run the same scheduler forward as a simulation against the current queue.
  # Assign queued items to the next-free station; the projection yields
  # `projected_start_at` and `projected_ready_at` per item. **Order ETA = max
  # over its items**, multiplied by `eta_safety_factor`."
  #
  # This is `ProjectEta` with the ActiveRecord taken out — same algorithm, same
  # `Scheduler.pick_next`, driven by the simulator's own structures. It exists
  # separately because `ProjectEta` reaches for `OrderItem`, `PrepTimeStat` and
  # `SchedulerStateStore`, none of which a simulated shop has; the parts that
  # must not diverge are the loop below and §7.1's max-over-items rule.
  #
  # **Why not the naive estimate.** The simulator used to renege on
  # `queued_seconds / stations` — ADR-0004's formula, which §7.1 replaced in
  # production precisely because it "has no idea that fair queuing reorders
  # work". Quoting one number and measuring another would make §10.4's ETA
  # error a report on a formula the shop no longer uses.
  #
  # **It must never touch the live state.** `pick_next` mutates what it is given
  # — drawing down deficits, advancing the ring pointer, shifting items off flow
  # queues (§6.2). Every flow here is rebuilt fresh and the pointer is copied by
  # value, so quoting a customer cannot reorder what the kitchen makes next.
  # That is the same rule `ProjectEta` states for itself, and it is easier to
  # break here because the state is in memory rather than behind Redis.
  class Projection
    # The projection is bounded by the queue: each pass either dispatches a
    # drink or stops. Mirrors `ProjectEta::MAX_DISPATCHES` so a scheduler bug
    # surfaces as an error rather than a hung simulation.
    MAX_DISPATCHES = 5_000

    # How far ahead the shop will project before giving up and saying "longer
    # than this" (seconds).
    #
    # Not a performance hack with a story attached — though it is also that.
    # Past this point the number stops carrying information:
    #
    # - **Behaviour is already saturated.** §10.3's renege curve tops out at 80%
    #   by a 24-minute quote. Every value beyond that produces the same
    #   decision, so computing it precisely changes nothing anyone observes.
    # - **No shop shows it.** A live estimate of three hours is not an estimate,
    #   and §7.3's argument is about a board customers trust.
    #
    # It also bounds the work: without it, an order arriving at 2.5x demand
    # joins the end of the DRR ring, so the projection must dispatch the entire
    # backlog before reaching it — quadratic in a queue that grows all day, and
    # measured at over ten minutes for a single simulated shift.
    #
    # Orders that hit the cap are reported rather than hidden: their quote is a
    # floor, and `Metrics` excludes them from ETA error with a count, the same
    # way `p90_meaningful` refuses to call a maximum a percentile.
    HORIZON_SECONDS = 3_600

    class ProjectionOverflow < StandardError; end

    # @param orders [Array<Simulator::Order>] every order in the shop, including
    #   the one being quoted — a customer's own drinks are part of their wait
    # @param stations [Array<Hash>] the world's stations, with `busy_until`
    # @param now [Float] the simulated clock
    # @param config [Scheduler::Config]
    # @param safety_factor [Float] §7.1's `eta_safety_factor`
    # @param target [Object, nil] quote only this order, and stop as soon as its
    #   answer is final. `ProjectEta` has no equivalent because the board wants
    #   every open order at once; a customer at the counter wants one number,
    #   and projecting the rest of a saturated queue to find it is work nobody
    #   reads. See `#finished?` for why stopping early cannot change the answer.
    def initialize(orders:, stations:, now:, config:, safety_factor:, target: nil)
      @orders = orders
      @stations = stations
      @now = now
      @config = config
      @safety_factor = safety_factor
      @target = target
    end

    # Whether the projection gave up at the horizon, making every quote it
    # returned a lower bound rather than an estimate. Only meaningful after
    # `call`.
    #
    # @return [Boolean]
    def capped?
      @capped == true
    end

    # @return [Hash{Object => Float}] order id => seconds until ready
    def call
      promised = @orders.to_h { |order| [ order.id, order.promised_at ] }

      project.to_h do |id, time|
        seconds = time - @now
        # A promise is the time the customer chose, not an estimate, so §7.1's
        # safety factor does not apply to it — the same rule `ProjectEta` states.
        [ id, [ promised[id] ? seconds : seconds * @safety_factor, 0.0 ].max ]
      end
    end

    private

    def project
      ready_at = {}
      free_at = station_free_times
      state = fresh_state
      target_flow = state.flows.find { |flow| flow.id == @target }
      dispatches = 0

      # Drinks already being made are invisible to `pick_next` — the flow set is
      # built from undispatched drinks only (§6.5) — so an order whose every
      # drink is in progress would fall out of the projection entirely and quote
      # as ready while a barista is still making it.
      seed_in_progress(ready_at)

      loop do
        dispatches += 1
        raise ProjectionOverflow, "projection exceeded #{MAX_DISPATCHES} dispatches" if dispatches > MAX_DISPATCHES

        # Whichever station frees first takes the next drink, and the clock jumps
        # to that moment — so aging (§6.2) and backward scheduling are evaluated
        # at the time the decision would really be made rather than at `now`.
        index = free_at.each_index.min_by { |i| free_at[i] }
        clock = free_at[index]

        # Every station is already busy past the horizon, so nothing dispatched
        # from here can land inside it.
        if clock - @now > HORIZON_SECONDS
          @capped = true
          break
        end

        picked = Scheduler.pick_next(state, clock)
        break if picked.nil?

        finish = clock + picked[:item].prep_seconds
        free_at[index] = finish

        # §7.1: "Order ETA = max over its items."
        id = picked[:flow].id
        ready_at[id] = [ ready_at[id], finish ].compact.max

        break if finished?(target_flow)
      end

      order_ahead(floor_capped(ready_at))
    end

    # An order the projection never reached has no answer, and the default that
    # would fill the gap is zero — the same defect as an unprojected order-ahead
    # (`ProjectEta#order_ahead`), reappearing by a different route. Its quote is
    # a floor: everything still queued lands somewhere past the horizon.
    def floor_capped(ready_at)
      return ready_at unless @capped

      @orders.each { |order| ready_at[order.id] ||= @now + HORIZON_SECONDS }

      ready_at
    end

    # Once the quoted order has no undispatched drinks left, every one of its
    # items has a projected finish and §7.1's max over them cannot move — later
    # dispatches belong to other orders. Stopping here is an optimisation with
    # no effect on the answer, which is why it is safe at saturation where it
    # matters most: at 2.2× demand the queue is hundreds of drinks deep and a
    # small order's own drinks are placed in the first few passes.
    #
    # A nil flow means the order had nothing queued to begin with — every drink
    # already in progress — and `seed_in_progress` has already answered for it.
    def finished?(target_flow)
      return false if @target.nil?

      target_flow.nil? || target_flow.empty?
    end

    # §6.2 schedules a promise backward, so `pick_next` refuses to dispatch it
    # until its start time arrives and it never reaches the loop above. Without
    # this it falls out of the projection and quotes zero — the same defect
    # `ProjectEta#order_ahead` fixes, and the reason this file exists as a
    # deliberate mirror rather than an independent implementation.
    def order_ahead(ready_at)
      @orders.each do |order|
        next if order.promised_at.nil?

        ready_at[order.id] = [ ready_at[order.id], order.promised_at ].compact.max
      end

      ready_at
    end

    # Nominal `prep_seconds`, never `actual_prep_seconds`. Production projects
    # from the seeded guess or §7.3's learned EWMA and cannot know what a drink
    # will really take — projecting from the realised time would quote a shop
    # that can see the future, and the gap between the two is precisely the
    # error §10.4 asks us to report.
    def seed_in_progress(ready_at)
      @orders.each do |order|
        order.items.each do |drink|
          next if drink.started_at.nil? || drink.finished_at

          finish = [ drink.started_at + drink.prep_seconds, @now ].max
          ready_at[order.id] = [ ready_at[order.id], finish ].compact.max
        end
      end
    end

    # A drink already being made blocks its station until it is done. Assuming
    # every station is free now is what would quote the next customer a wait
    # shorter than the drink already in the hand of the barista who would make
    # theirs. A drink running past its estimate frees its station *now* rather
    # than in the past — the honest reading is that it is nearly done.
    def station_free_times
      @stations.map { |station| [ station[:busy_until] || @now, @now ].max }
    end

    # Deficits are copied by value and the ring starts where it stands. Sharing
    # the live flows would let a quote consume the real queue's deficits.
    def fresh_state
      flows = @orders.filter_map do |order|
        queued = order.items.reject(&:started_at)
        next if queued.empty?

        Scheduler::Flow.new(
          id: order.id, arrived_at: order.arrived_at, promised_at: order.promised_at,
          queue: queued.map do |drink|
            Scheduler::Item.new(id: drink.id, prep_seconds: drink.prep_seconds,
                                enqueued_at: order.arrived_at, remake: drink.remake?)
          end,
          made_count: order.items.count(&:finished_at),
          total_items: order.items.size
        )
      end

      Scheduler::State.new(flows: flows, config: @config)
    end
  end
end
